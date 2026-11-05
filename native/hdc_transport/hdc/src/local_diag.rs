//! Read the OS debugging user's local TCP listener through the kernel ABI.
//! This sends no TCP connections and exposes no other applications' sockets.
use std::io;

fn listener(message: &[u8]) -> Option<u16> {
    // inet_diag_msg from the SDK's linux/inet_diag.h, in native byte order
    // except network addresses and ports.
    if message.len() < 72 || !matches!(message[0], 2 | 10) || message[1] != 10 ||
        u32::from_ne_bytes(message[64..68].try_into().ok()?) != 2000 ||
        !message[8..24].iter().all(|byte| *byte == 0) { return None; }
    let port = u16::from_be_bytes(message[4..6].try_into().ok()?);
    (port >= 1024).then_some(port)
}

#[cfg(any(target_os = "linux", target_env = "ohos"))]
fn ports(family: u8) -> io::Result<Vec<u16>> {
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    use std::time::{Duration, Instant};
    let descriptor = unsafe { libc::socket(libc::AF_NETLINK, libc::SOCK_DGRAM | libc::SOCK_CLOEXEC, 4) };
    if descriptor < 0 { return Err(io::Error::last_os_error()); }
    let socket = unsafe { OwnedFd::from_raw_fd(descriptor) };
    let mut kernel: libc::sockaddr_nl = unsafe { std::mem::zeroed() };
    kernel.nl_family = libc::AF_NETLINK as libc::sa_family_t;
    let mut request = [0u8; 72];
    request[0..4].copy_from_slice(&72u32.to_ne_bytes());
    request[4..6].copy_from_slice(&20u16.to_ne_bytes()); // SOCK_DIAG_BY_FAMILY
    request[6..8].copy_from_slice(&0x301u16.to_ne_bytes()); // REQUEST | DUMP
    request[8..12].copy_from_slice(&1u32.to_ne_bytes());
    request[16] = family;
    request[17] = libc::IPPROTO_TCP as u8;
    request[20..24].copy_from_slice(&(1u32 << 10).to_ne_bytes()); // TCP_LISTEN only
    request[64..72].fill(255); // INET_DIAG_NOCOOKIE
    let sent = unsafe { libc::sendto(socket.as_raw_fd(), request.as_ptr() as *const _, request.len(), 0,
        &kernel as *const _ as *const libc::sockaddr, std::mem::size_of_val(&kernel) as libc::socklen_t) };
    if sent < 0 { return Err(io::Error::last_os_error()); }
    let deadline = Instant::now() + Duration::from_millis(600);
    let mut candidates = Vec::new();
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() { return Err(io::Error::new(io::ErrorKind::TimedOut, "socket diagnostics timed out")); }
        let mut poll = libc::pollfd { fd: socket.as_raw_fd(), events: libc::POLLIN, revents: 0 };
        let ready = unsafe { libc::poll(&mut poll, 1, remaining.as_millis().max(1) as i32) };
        if ready < 0 { return Err(io::Error::last_os_error()); }
        if ready == 0 { continue; }
        let mut bytes = [0u8; 65536];
        let mut source: libc::sockaddr_nl = unsafe { std::mem::zeroed() };
        let mut source_len = std::mem::size_of_val(&source) as libc::socklen_t;
        let length = unsafe { libc::recvfrom(socket.as_raw_fd(), bytes.as_mut_ptr() as *mut _, bytes.len(), 0,
            &mut source as *mut _ as *mut libc::sockaddr, &mut source_len) };
        if length < 0 { return Err(io::Error::last_os_error()); }
        if source.nl_pid != 0 { continue; }
        let mut offset = 0usize;
        while offset + 16 <= length as usize {
            let header = &bytes[offset..offset + 16];
            let size = u32::from_ne_bytes(header[0..4].try_into().unwrap()) as usize;
            if size < 16 || offset + size > length as usize {
                return Err(io::Error::new(io::ErrorKind::InvalidData, "incomplete socket diagnostics"));
            }
            if u32::from_ne_bytes(header[8..12].try_into().unwrap()) == 1 {
                if u16::from_ne_bytes(header[6..8].try_into().unwrap()) & 0x10 != 0 {
                    return Err(io::Error::new(io::ErrorKind::Interrupted, "socket table changed"));
                }
                let body = &bytes[offset + 16..offset + size];
                match u16::from_ne_bytes(header[4..6].try_into().unwrap()) {
                    3 => return Ok(candidates),
                    2 if body.len() >= 4 => {
                        let error = i32::from_ne_bytes(body[..4].try_into().unwrap());
                        if error < 0 { return Err(io::Error::from_raw_os_error(-error)); }
                    }
                    20 => if let Some(port) = listener(body) { candidates.push(port); },
                    _ => {}
                }
            }
            offset += (size + 3) & !3;
        }
    }
}

pub fn debug_listener() -> io::Result<Option<u16>> {
    #[cfg(any(target_os = "linux", target_env = "ohos"))]
    {
        let mut candidates = ports(libc::AF_INET as u8)?;
        candidates.extend(ports(libc::AF_INET6 as u8)?);
        candidates.sort_unstable(); candidates.dedup();
        Ok(if candidates.len() == 1 { Some(candidates[0]) } else { None })
    }
    #[cfg(not(any(target_os = "linux", target_env = "ohos")))]
    { Ok(None) }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn only_the_debugging_users_wildcard_listener_is_a_candidate() {
        let mut value = [0u8; 72];
        value[0] = 2; value[1] = 10;
        value[4..6].copy_from_slice(&37477u16.to_be_bytes());
        value[64..68].copy_from_slice(&2000u32.to_ne_bytes());
        assert_eq!(listener(&value), Some(37477));
        value[64..68].copy_from_slice(&20020238u32.to_ne_bytes());
        assert_eq!(listener(&value), None);
        value[64..68].copy_from_slice(&2000u32.to_ne_bytes());
        value[8] = 127; assert_eq!(listener(&value), None);
        value[8] = 0; value[1] = 1; assert_eq!(listener(&value), None);
        assert_eq!(listener(&value[..71]), None);
    }
}
