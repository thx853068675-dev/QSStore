//! Bounded loopback-only fallback for devices that hide the listener table
//! and disable UDP discovery. No keys or installation commands are sent.
use hdc_protocol::config::{get_version, HdcCommand, TaskMessage, HANDSHAKE_MESSAGE};
use hdc_protocol::serializer::{concat_pack, unpack_payload_head, unpack_task_message,
    HdcDeserialize, HdcSerialize, SessionHandShake, HEAD_SIZE};
use std::io::{self, Read, Write};
use std::net::{Ipv4Addr, SocketAddr, TcpStream};
use std::sync::Mutex;
use std::time::{Duration, Instant};

static LAST_SCAN: Mutex<Option<Instant>> = Mutex::new(None);

fn read_until(stream: &mut TcpStream, mut bytes: &mut [u8], deadline: Instant) -> io::Result<()> {
    while !bytes.is_empty() {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() { return Err(io::Error::new(io::ErrorKind::TimedOut, "local discovery deadline")); }
        stream.set_read_timeout(Some(remaining))?;
        match stream.read(bytes) {
            Ok(0) => return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "local peer closed")),
            Ok(length) => bytes = &mut bytes[length..],
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error),
        }
    }
    Ok(())
}

pub(crate) fn daemon_reply_at(stream: &mut TcpStream, endpoint: SocketAddr, deadline: Instant) -> io::Result<bool> {
    let remaining = deadline.saturating_duration_since(Instant::now());
    if remaining.is_zero() { return Ok(false); }
    stream.set_write_timeout(Some(remaining))?;
    let request = SessionHandShake { banner: HANDSHAKE_MESSAGE.into(), auth_type: 0,
        session_id: rand::random(), connect_key: endpoint.to_string(),
        buf: String::new(), version: get_version() };
    stream.write_all(&concat_pack(&TaskMessage { channel_id: 0,
        command: HdcCommand::KernelHandshake, payload: request.serialize() }))?;
    let mut header = [0u8; HEAD_SIZE];
    read_until(stream, &mut header, deadline)?;
    let fields = unpack_payload_head(&header)?;
    let length = fields.head_size as usize + fields.data_size as usize;
    if length == 0 || length > 8192 { return Ok(false); }
    let mut message = Vec::with_capacity(HEAD_SIZE + length);
    message.extend_from_slice(&header); message.resize(HEAD_SIZE + length, 0);
    read_until(stream, &mut message[HEAD_SIZE..], deadline)?;
    let message = unpack_task_message(&message)?;
    Ok(message.command == HdcCommand::KernelHandshake &&
        SessionHandShake::deserialize(&message.payload)?.banner == HANDSHAKE_MESSAGE)
}

#[cfg(any(target_os = "linux", target_env = "ohos"))]
fn connected_batch(ports: &[u16]) -> Vec<(u16, TcpStream)> {
    use std::os::fd::{AsRawFd, FromRawFd, IntoRawFd, OwnedFd};
    let mut pending = Vec::new();
    for &port in ports {
        let descriptor = unsafe { libc::socket(libc::AF_INET,
            libc::SOCK_STREAM | libc::SOCK_NONBLOCK | libc::SOCK_CLOEXEC, 0) };
        if descriptor < 0 { break; }
        let socket = unsafe { OwnedFd::from_raw_fd(descriptor) };
        let mut address: libc::sockaddr_in = unsafe { std::mem::zeroed() };
        address.sin_family = libc::AF_INET as libc::sa_family_t;
        address.sin_port = port.to_be();
        address.sin_addr.s_addr = u32::from_ne_bytes([127, 0, 0, 1]);
        let result = unsafe { libc::connect(socket.as_raw_fd(), &address as *const _ as *const libc::sockaddr,
            std::mem::size_of_val(&address) as libc::socklen_t) };
        if result == 0 || io::Error::last_os_error().raw_os_error() == Some(libc::EINPROGRESS) {
            pending.push((port, socket));
        }
    }
    let mut events: Vec<libc::pollfd> = pending.iter().map(|(_, socket)| libc::pollfd {
        fd: socket.as_raw_fd(), events: libc::POLLOUT, revents: 0 }).collect();
    if events.is_empty() || unsafe { libc::poll(events.as_mut_ptr(), events.len() as libc::nfds_t, 2) } <= 0 {
        return Vec::new();
    }
    let mut connected = Vec::new();
    for ((port, socket), event) in pending.into_iter().zip(events) {
        if event.revents & libc::POLLOUT == 0 { continue; }
        let mut error: libc::c_int = 0;
        let mut size = std::mem::size_of_val(&error) as libc::socklen_t;
        let status = unsafe { libc::getsockopt(socket.as_raw_fd(), libc::SOL_SOCKET, libc::SO_ERROR,
            &mut error as *mut _ as *mut _, &mut size) };
        if status == 0 && error == 0 {
            let stream = unsafe { TcpStream::from_raw_fd(socket.into_raw_fd()) };
            if stream.set_nonblocking(false).is_ok() { connected.push((port, stream)); }
        }
    }
    connected
}

#[cfg(not(any(target_os = "linux", target_env = "ohos")))]
fn connected_batch(ports: &[u16]) -> Vec<(u16, TcpStream)> {
    ports.iter().filter_map(|&port| TcpStream::connect_timeout(
        &SocketAddr::from((Ipv4Addr::LOCALHOST, port)), Duration::from_millis(2))
        .ok().map(|stream| (port, stream))).collect()
}

fn scan(ports:impl Iterator<Item=u16>,budget:Duration)->Option<u16>{scan_cancelled(ports,budget,||false)}
fn scan_cancelled(mut ports:impl Iterator<Item=u16>,budget:Duration,cancelled:impl Fn()->bool)->Option<u16>{
    let deadline = Instant::now() + budget;
    loop {
        if cancelled()||Instant::now() >= deadline { break; }
        let batch: Vec<u16> = ports.by_ref().take(64).collect();
        if batch.is_empty() { break; }
        // Closed loopback ports return immediately. Dropped requests cannot
        // hold a worker indefinitely, and every stream is closed in this scope.
        for (port, mut stream) in connected_batch(&batch) {
            if cancelled(){return None;}
            let reply_deadline = deadline.min(Instant::now() + Duration::from_millis(120));
            if daemon_reply_at(&mut stream, SocketAddr::from((Ipv4Addr::LOCALHOST, port)), reply_deadline).unwrap_or(false) { return Some(port); }
        }
    }
    None
}

pub fn discover()->Option<u16>{discover_cancelled(||false)}
pub fn discover_cancelled(cancelled:impl Fn()->bool)->Option<u16>{
    let mut last = LAST_SCAN.lock().ok()?;
    // Commands are serialized too; this prevents frequent foreground/network
    // events from repeatedly scanning when wireless debugging is disabled.
    if last.is_some_and(|last| last.elapsed() < Duration::from_secs(10)) { return None; }
    *last = Some(Instant::now());
    scan_cancelled(std::iter::once(12345).chain(32768..=65535).chain(10000..32768),Duration::from_secs(4),cancelled)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn cancelled_local_fallback_does_not_attempt_a_connection() {
        let listener=std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        assert_eq!(scan_cancelled(std::iter::repeat(listener.local_addr().unwrap().port()),Duration::from_secs(4),||true),None);
        assert!(listener.accept().is_err());
    }
    #[test]
    fn an_open_port_without_an_hdc_reply_is_rejected() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let worker = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            stream.write_all(b"HTTP/1.1 400 Bad Request\r\n").unwrap();
        });
        assert_eq!(scan(std::iter::once(port), Duration::from_secs(1)), None);
        worker.join().unwrap();
    }

    #[test]
    fn loopback_fallback_requires_an_hdc_handshake() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let worker = std::thread::spawn(move || {
            let (mut stream, peer) = listener.accept().unwrap();
            assert!(peer.ip().is_loopback());
            let mut header = [0u8; HEAD_SIZE]; stream.read_exact(&mut header).unwrap();
            let fields = unpack_payload_head(&header).unwrap();
            let mut body = vec![0u8; fields.head_size as usize + fields.data_size as usize];
            stream.read_exact(&mut body).unwrap();
            let response = SessionHandShake { banner: HANDSHAKE_MESSAGE.into(),
                auth_type: 2, session_id: 1, connect_key: String::new(), buf: "challenge".into(), version: get_version() };
            stream.write_all(&concat_pack(&TaskMessage { channel_id: 0,
                command: HdcCommand::KernelHandshake, payload: response.serialize() })).unwrap();
        });
        assert_eq!(scan(std::iter::once(port), Duration::from_secs(1)), Some(port));
        worker.join().unwrap();
        assert_eq!(scan(std::iter::once(port), Duration::from_millis(10)), None);
        assert_eq!(scan(std::iter::repeat(port), Duration::ZERO), None);
    }
}
