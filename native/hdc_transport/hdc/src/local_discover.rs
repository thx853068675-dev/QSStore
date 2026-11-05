//! Local daemon discovery and bounded, read-only discovery on private LAN interfaces.
use hdc_protocol::config::{HANDSHAKE_MESSAGE, SERVER_DEFAULT_PORT};
use std::io;
use std::net::UdpSocket;
use std::time::{Duration, Instant};

// Only a unique wildcard TCP listener owned by the OS debugging user is a
// candidate. HdcDeviceBridge still requires an authenticated HDC/UDID check.
fn debug_listener_ports(table: &str) -> Vec<u16> {
    table.lines().filter_map(|line| {
        let fields: Vec<&str> = line.split_whitespace().collect();
        if fields.len() < 8 || fields[3] != "0A" || fields[7] != "2000" { return None; }
        let (address, port) = fields[1].split_once(':')?;
        if (address.len() != 8 && address.len() != 32) || !address.bytes().all(|b| b == b'0') { return None; }
        u16::from_str_radix(port, 16).ok().filter(|port| *port >= 1024)
    }).collect()
}

fn debug_listener_port() -> Option<u16> {
    let mut ports = Vec::new();
    for path in ["/proc/net/tcp", "/proc/net/tcp6"] {
        if let Ok(table) = std::fs::read_to_string(path) { ports.extend(debug_listener_ports(&table)); }
    }
    ports.sort_unstable(); ports.dedup();
    if ports.len() == 1 { Some(ports[0]) } else { None }
}

fn parse_port(bytes: &[u8]) -> Option<u16> {
    let text = std::str::from_utf8(bytes).ok()?;
    let value = text.strip_prefix(HANDSHAKE_MESSAGE)?.strip_prefix('-')?;
    if value.is_empty() || !value.bytes().all(|b| b.is_ascii_digit()) { return None; }
    let port: u16 = value.parse().ok()?;
    (port >= 1024).then_some(port)
}

#[cfg(unix)]
fn socket(port: u16, local: [u8; 4]) -> io::Result<UdpSocket> {
    use std::os::fd::FromRawFd;
    // The daemon replies to UDP 8710, irrespective of the request's source
    // port. A distinct loopback address and REUSEADDR avoid taking over its
    // wildcard listener. Responses are validated against this phone below:
    // a wildcard daemon can reply from a different local interface.
    let fd = unsafe { libc::socket(libc::AF_INET, libc::SOCK_DGRAM, 0) };
    if fd < 0 { return Err(io::Error::last_os_error()); }
    let socket = unsafe { UdpSocket::from_raw_fd(fd) };
    let reuse: libc::c_int = 1;
    let result = unsafe { libc::setsockopt(fd, libc::SOL_SOCKET, libc::SO_REUSEADDR,
        &reuse as *const _ as *const libc::c_void, std::mem::size_of_val(&reuse) as libc::socklen_t) };
    if result < 0 { return Err(io::Error::last_os_error()); }
    let mut addr: libc::sockaddr_in = unsafe { std::mem::zeroed() };
    addr.sin_family = libc::AF_INET as libc::sa_family_t;
    addr.sin_port = port.to_be();
    addr.sin_addr.s_addr = u32::from_ne_bytes(local);
    #[cfg(any(target_os = "macos", target_os = "ios"))]
    { addr.sin_len = std::mem::size_of_val(&addr) as u8; }
    let result = unsafe { libc::bind(fd, &addr as *const _ as *const libc::sockaddr,
        std::mem::size_of_val(&addr) as libc::socklen_t) };
    if result < 0 { return Err(io::Error::last_os_error()); }
    Ok(socket)
}

fn local_reply(source: std::net::SocketAddr, port: u16, local: [u8; 4], peer: [u8; 4]) -> bool {
    source.port() == port && (source.ip().is_loopback() ||
        source.ip() == std::net::Ipv4Addr::from(local) || source.ip() == std::net::Ipv4Addr::from(peer))
}

#[cfg(unix)]
fn discover_at(port: u16, timeout: Duration, local: [u8; 4], peer: [u8; 4]) -> io::Result<Option<u16>> {
    let socket = socket(port, local)?;
    socket.send_to(HANDSHAKE_MESSAGE.as_bytes(), (std::net::Ipv4Addr::from(peer), port))?;
    let deadline = Instant::now() + timeout;
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() { return Ok(None); }
        socket.set_read_timeout(Some(remaining))?;
        let mut bytes = [0u8; 256];
        match socket.recv_from(&mut bytes) {
            Ok((length, source)) if local_reply(source, port, local, peer) =>
                if let Some(port) = parse_port(&bytes[..length]) { return Ok(Some(port)); },
            Ok(_) => continue,
            Err(error) if matches!(error.kind(), io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut |
                io::ErrorKind::ConnectionRefused) => return Ok(None),
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error),
        }
    }
}

#[cfg(any(target_os = "linux", target_env = "ohos"))]
fn wifi_address() -> Option<[u8; 4]> {
    unsafe {
        let mut list: *mut libc::ifaddrs = std::ptr::null_mut();
        if libc::getifaddrs(&mut list) != 0 { return None; }
        let mut current = list;
        let mut address = None;
        while !current.is_null() {
            let row = &*current;
            if !row.ifa_name.is_null() && !row.ifa_addr.is_null() &&
                (*row.ifa_addr).sa_family as i32 == libc::AF_INET &&
                std::ffi::CStr::from_ptr(row.ifa_name).to_bytes() == b"wlan0" {
                let ipv4 = &*(row.ifa_addr as *const libc::sockaddr_in);
                address = Some(ipv4.sin_addr.s_addr.to_ne_bytes()); break;
            }
            current = row.ifa_next;
        }
        libc::freeifaddrs(list);
        address
    }
}

static LOCAL_GENERATION:std::sync::atomic::AtomicU64=std::sync::atomic::AtomicU64::new(0);
pub fn cancel_local_discovery(){LOCAL_GENERATION.fetch_add(1,std::sync::atomic::Ordering::Relaxed);}
fn local_cancelled(generation:u64)->bool{LOCAL_GENERATION.load(std::sync::atomic::Ordering::Relaxed)!=generation}
pub fn discover_local_port() -> io::Result<Option<u16>> {
    let generation=LOCAL_GENERATION.load(std::sync::atomic::Ordering::Relaxed);
    // Linux/OHOS treats the entire 127/8 range as loopback. Other hosts may
    // require an administrator-created alias, so discovery stays unavailable.
    #[cfg(any(target_os = "linux", target_env = "ohos"))]
    {
        if local_cancelled(generation){return Ok(None);}
        if let Some(port) = debug_listener_port() { return Ok(Some(port)); }
        let diagnostic = crate::local_diag::debug_listener();
        if let Ok(Some(port)) = diagnostic { return Ok(Some(port)); }
        if local_cancelled(generation){return Ok(None);}
        if let Ok(Some(port)) = discover_at(SERVER_DEFAULT_PORT, Duration::from_millis(200),
            [127, 0, 0, 2], [127, 0, 0, 1]) { return Ok(Some(port)); }
        if let Some(wifi) = wifi_address() {
            // Both addresses belong to this phone. Some vendor daemons ignore
            // discovery whose source is loopback, so use the phone's WLAN IP.
            for (local, peer) in [(wifi, wifi), (wifi, [127, 0, 0, 1]), ([127, 0, 0, 2], wifi)] {
                if local_cancelled(generation){return Ok(None);}
                if local_cancelled(generation){return Ok(None);}
        if let Ok(Some(port)) = discover_at(SERVER_DEFAULT_PORT, Duration::from_millis(200),
                    local, peer) { return Ok(Some(port)); }
            }
        }
        if local_cancelled(generation){return Ok(None);}
        if let Some(port) = crate::local_tcp::discover_cancelled(||local_cancelled(generation)) { return Ok(Some(port)); }
        diagnostic.map(|_| None)
    }
    #[cfg(not(any(target_os = "linux", target_env = "ohos")))]
    { Ok(None) }
}

/// Ask only the user-selected LAN address. No subnet scan, TCP login or auth prompts.
pub fn discover_lan_port(address: &str) -> io::Result<Option<u16>> {
    let peer: std::net::Ipv4Addr = address.parse().map_err(|_|io::Error::new(io::ErrorKind::InvalidInput,"invalid LAN address"))?;
    if !peer.is_private() { return Err(io::Error::new(io::ErrorKind::InvalidInput,"LAN address is required")); }
    #[cfg(unix)] {
        let route=UdpSocket::bind("0.0.0.0:0")?;
        route.connect((peer,SERVER_DEFAULT_PORT))?;
        let std::net::IpAddr::V4(local)=route.local_addr()?.ip() else {return Ok(None);};
        if !local.is_private() || local==peer {return Ok(None);}
        let socket=socket(SERVER_DEFAULT_PORT,local.octets())?;
        socket.send_to(HANDSHAKE_MESSAGE.as_bytes(),(peer,SERVER_DEFAULT_PORT))?;
        let deadline=Instant::now()+Duration::from_millis(900);
        loop {
            let remaining=deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero(){return Ok(None);}
            socket.set_read_timeout(Some(remaining))?;
            let mut bytes=[0u8;256];
            match socket.recv_from(&mut bytes) {
                Ok((length,source)) if source.ip()==peer && source.port()==SERVER_DEFAULT_PORT =>
                  if let Some(port)=parse_port(&bytes[..length]).filter(|value|*value>=10000){return Ok(Some(port));},
                Ok(_)=>{},
                Err(error) if matches!(error.kind(),io::ErrorKind::TimedOut|io::ErrorKind::WouldBlock)=>return Ok(None),
                Err(error)=>return Err(error)
            }
        }
    }
    #[cfg(not(unix))] {Ok(None)}
}

#[cfg(unix)]
pub(crate) fn lan_interfaces() -> Vec<([u8;4],[u8;4])> {
    let mut result=Vec::new();
    unsafe {
        let mut list: *mut libc::ifaddrs=std::ptr::null_mut();
        if libc::getifaddrs(&mut list)!=0{return result;}
        let mut current=list;
        while !current.is_null() {
            let row=&*current;
            if !row.ifa_name.is_null()&&!row.ifa_addr.is_null()&&!row.ifa_netmask.is_null()&&
                (*row.ifa_addr).sa_family as i32==libc::AF_INET&&
                row.ifa_flags as i32&libc::IFF_UP!=0&&row.ifa_flags as i32&libc::IFF_BROADCAST!=0 {
                let name=std::ffi::CStr::from_ptr(row.ifa_name).to_bytes();
                // Physical WLAN/Ethernet only; VPN/tunnel interfaces are not discovery targets.
                if name.starts_with(b"wlan")||name.starts_with(b"wifi")||name.starts_with(b"en")||name.starts_with(b"eth") {
                    let ip=&*(row.ifa_addr as *const libc::sockaddr_in);
                    let mask=&*(row.ifa_netmask as *const libc::sockaddr_in);
                    let ip=ip.sin_addr.s_addr.to_ne_bytes();let mask=mask.sin_addr.s_addr.to_ne_bytes();
                    if std::net::Ipv4Addr::from(ip).is_private()&&mask!=[0;4]&&mask!=[255;4]&&!result.contains(&(ip,mask)) {
                        result.push((ip,mask));
                    }
                }
            }
            current=row.ifa_next;
        }
        libc::freeifaddrs(list);
    }
    result.truncate(3);result
}
fn peer_on_lan(ip:std::net::Ipv4Addr,local:[u8;4],mask:[u8;4])->bool {
    let octets=ip.octets();
    if !ip.is_private()||octets==local||
      !octets.iter().zip(local).zip(mask).all(|((&remote,own),netmask)|remote&netmask==own&netmask){return false;}
    let network:Vec<u8>=local.iter().zip(mask).map(|(&ip,mask)|ip&mask).collect();
    let broadcast:Vec<u8>=local.iter().zip(mask).map(|(&ip,mask)|ip|!mask).collect();
    octets.as_slice()!=network&&octets.as_slice()!=broadcast
}
fn lan_reply(source:std::net::SocketAddr,bytes:&[u8],local:[u8;4],mask:[u8;4])->Option<String> {
    let std::net::IpAddr::V4(ip)=source.ip() else{return None;};
    if source.port()!=SERVER_DEFAULT_PORT||!peer_on_lan(ip,local,mask){return None;}
    parse_port(bytes).filter(|port|*port>=10000).map(|port|format!("{ip}:{port}"))
}

fn directed_peers(peers:&[std::net::Ipv4Addr],local:[u8;4],mask:[u8;4])->Vec<std::net::Ipv4Addr>{
    let mut result=Vec::new();
    for &peer in peers{
        if peer_on_lan(peer,local,mask)&&!result.contains(&peer){result.push(peer);if result.len()==128{break;}}
    }
    result
}

/// Retry only IPs already enumerated on the physical LAN. UDP replies publish
/// a port hint; authenticated identity is still required before installation.
pub fn discover_peer_ports_cancelled(peers:&[std::net::Ipv4Addr],cancel:&std::sync::atomic::AtomicBool,
    deadline:Instant,mut found:impl FnMut(String))->io::Result<usize>{
    #[cfg(unix)]{
        let mut sockets=Vec::new();
        for (ip,mask) in lan_interfaces(){
            let targets=directed_peers(peers,ip,mask);if targets.is_empty(){continue;}
            if cancel.load(std::sync::atomic::Ordering::Relaxed)||Instant::now()>=deadline{return Ok(0);}
            let Ok(socket)=socket(SERVER_DEFAULT_PORT,ip) else{continue;};socket.set_nonblocking(true)?;
            sockets.push((socket,ip,mask,targets));
        }
        if sockets.is_empty(){return Ok(0);}
        let started=Instant::now();let deadline=deadline.min(started+Duration::from_millis(900));
        let mut next=0;let rounds=[0,180,480];let mut seen=std::collections::HashSet::new();let mut sent=0;
        while !cancel.load(std::sync::atomic::Ordering::Relaxed)&&Instant::now()<deadline{
            if next<rounds.len()&&started.elapsed().as_millis()>=rounds[next]{
                next+=1;
                for (socket,_,_,targets) in &sockets{for peer in targets{
                    if cancel.load(std::sync::atomic::Ordering::Relaxed)||Instant::now()>=deadline{break;}
                    if !seen.contains(peer)&&socket.send_to(HANDSHAKE_MESSAGE.as_bytes(),(*peer,SERVER_DEFAULT_PORT)).is_ok(){sent+=1;}
                }}
            }
            for (socket,ip,mask,targets) in &sockets{
                for _ in 0..48{
                    let mut bytes=[0u8;256];
                    match socket.recv_from(&mut bytes){
                        Ok((length,source))=>if let Some(endpoint)=lan_reply(source,&bytes[..length],*ip,*mask){
                            let std::net::IpAddr::V4(peer)=source.ip() else{continue;};
                            if targets.contains(&peer)&&seen.insert(peer){found(endpoint);}
                        },
                        Err(error) if error.kind()==io::ErrorKind::Interrupted=>continue,
                        Err(_)=>break,
                    }
                }
            }
            if sockets.iter().all(|(_,_,_,targets)|targets.iter().all(|peer|seen.contains(peer))){break;}
            std::thread::sleep(Duration::from_millis(15));
        }
        Ok(sent)
    }
    #[cfg(not(unix))]{let _=(peers,cancel,deadline,&mut found);Ok(0)}
}

fn nearby_hosts(local:[u8;4],mask:[u8;4])->Vec<std::net::Ipv4Addr> {
    let own=u32::from_be_bytes(local);let mask=u32::from_be_bytes(mask);
    let network=own&mask;let broadcast=network|!mask;
    // Prime neighbour discovery with at most 254 read-only UDP queries, never a wide network sweep.
    if broadcast.saturating_sub(network)>255||broadcast<=network+1{return Vec::new();}
    ((network+1)..broadcast).filter(|address|*address!=own).map(std::net::Ipv4Addr::from).collect()
}
/// Directed LAN discovery, with a small-subnet UDP fallback. No TCP probes or login.
pub fn discover_lan_devices()->io::Result<Vec<String>> {
    discover_lan_devices_cancelled(&std::sync::atomic::AtomicBool::new(false),Instant::now()+Duration::from_millis(700))
}
pub fn discover_lan_devices_cancelled(cancel:&std::sync::atomic::AtomicBool,deadline:Instant)->io::Result<Vec<String>> {
    #[cfg(unix)] {
        let mut sockets=Vec::new();
        for (ip,mask) in lan_interfaces() {
            if cancel.load(std::sync::atomic::Ordering::Relaxed)||Instant::now()>=deadline {return Ok(Vec::new());}
            let Ok(socket)=socket(SERVER_DEFAULT_PORT,ip) else{continue;};
            socket.set_broadcast(true)?;socket.set_nonblocking(true)?;
            let broadcast=[ip[0]|!mask[0],ip[1]|!mask[1],ip[2]|!mask[2],ip[3]|!mask[3]];
            if socket.send_to(HANDSHAKE_MESSAGE.as_bytes(),(std::net::Ipv4Addr::from(broadcast),SERVER_DEFAULT_PORT)).is_ok(){
                sockets.push((socket,ip,mask));
            }
        }
        if sockets.is_empty(){return Ok(Vec::new());}
        let started=Instant::now();let deadline=deadline.min(started+Duration::from_millis(700));let mut found=Vec::new();let mut fallback=false;
        while !cancel.load(std::sync::atomic::Ordering::Relaxed)&&Instant::now()<deadline&&found.len()<24 {
            if !fallback&&started.elapsed()>=Duration::from_millis(100) {
                fallback=true;
                // One daemon's broadcast reply says nothing about quieter peers.
                // Always prime the small subnet so candidate enumeration is not
                // limited to addresses already present in the neighbour cache.
                for (socket,ip,mask) in &sockets {
                    for peer in nearby_hosts(*ip,*mask){if cancel.load(std::sync::atomic::Ordering::Relaxed)||Instant::now()>=deadline{break;}let _=socket.send_to(HANDSHAKE_MESSAGE.as_bytes(),(peer,SERVER_DEFAULT_PORT));}
                }
            }
            for (socket,ip,mask) in &sockets {
                let mut bytes=[0u8;256];
                // Bound traffic work as well as elapsed time on noisy LANs.
                for _ in 0..48 {
                    match socket.recv_from(&mut bytes) {
                        Ok((length,source))=>if let Some(target)=lan_reply(source,&bytes[..length],*ip,*mask){
                            // The same daemon changing port updates its endpoint rather than duplicating it.
                            if let Some(index)=found.iter().position(|old:&String|old.split_once(':').map(|v|v.0)==target.split_once(':').map(|v|v.0)){
                                found[index]=target;
                            }else if found.len()<24{found.push(target);}
                        },
                        Err(error) if error.kind()==io::ErrorKind::WouldBlock=>break,
                        Err(error) if error.kind()==io::ErrorKind::Interrupted=>continue,
                        Err(_)=>break,
                    }
                }
            }
            std::thread::sleep(Duration::from_millis(15));
        }
        Ok(found)
    }
    #[cfg(not(unix))] {Ok(Vec::new())}
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn directed_queries_only_use_unique_physical_lan_candidates_and_cap_the_work(){
        let peers=(1..=254).map(|n|std::net::Ipv4Addr::new(192,168,3,n)).chain([
            std::net::Ipv4Addr::new(192,168,3,1),std::net::Ipv4Addr::new(192,168,4,1),std::net::Ipv4Addr::new(8,8,8,8)]).collect::<Vec<_>>();
        let found=directed_peers(&peers,[192,168,3,20],[255,255,255,0]);assert_eq!(found.len(),128);
        assert!(!found.contains(&std::net::Ipv4Addr::new(192,168,3,20)));
        assert_eq!(found.iter().collect::<std::collections::HashSet<_>>().len(),found.len());
        assert!(directed_peers(&["192.168.4.8".parse().unwrap(),"192.168.3.0".parse().unwrap(),"192.168.3.255".parse().unwrap()],
            [192,168,3,20],[255,255,255,0]).is_empty());
    }
    #[test]
    fn cancelled_directed_queries_do_not_send_or_publish_a_port(){
        let cancelled=std::sync::atomic::AtomicBool::new(true);
        assert_eq!(discover_peer_ports_cancelled(&["192.168.3.8".parse().unwrap()],&cancelled,Instant::now()+Duration::from_secs(2),
            |_|panic!("cancelled query published a peer")).unwrap(),0);
    }
    #[test]
    fn fallback_is_bounded_to_the_actual_small_subnet() {
        let peers=nearby_hosts([192,168,3,20],[255,255,255,0]);
        assert_eq!(peers.len(),253);
        assert!(!peers.contains(&std::net::Ipv4Addr::new(192,168,3,20)));
        assert!(!peers.contains(&std::net::Ipv4Addr::new(192,168,3,255)));
        assert!(nearby_hosts([10,0,0,20],[255,0,0,0]).is_empty());
        assert_eq!(nearby_hosts([192,168,3,2],[255,255,255,252]),vec![std::net::Ipv4Addr::new(192,168,3,1)]);
    }
    #[test]
    fn lan_discovery_accepts_only_debug_daemons_in_the_actual_subnet() {
        let check=|peer:&str,payload:&[u8]|lan_reply(peer.parse().unwrap(),payload,[192,168,3,20],[255,255,255,0]);
        assert_eq!(check("192.168.3.5:8710",b"OHOS HDC-54321"),Some("192.168.3.5:54321".into()));
        for peer in ["192.168.3.20:8710","192.168.3.255:8710","192.168.3.0:8710","192.168.4.5:8710","8.8.8.8:8710","192.168.3.5:8709"]{
            assert_eq!(check(peer,b"OHOS HDC-54321"),None);
        }
        for payload in [b"HTTP-54321".as_slice(),b"OHOS HDC-9999",b"OHOS HDC-65536",b"OHOS HDC-54321junk"]{
            assert_eq!(check("192.168.3.5:8710",payload),None);
        }
    }
    #[test]
    fn discovery_replies_stay_on_this_phone() {
        let check = |address: &str| local_reply(address.parse().unwrap(), 8710,
            [192, 168, 3, 160], [127, 0, 0, 1]);
        assert!(check("192.168.3.160:8710"));
        assert!(check("127.0.0.1:8710"));
        assert!(!check("192.168.3.161:8710"));
        assert!(!check("192.168.3.160:8711"));
    }

    #[test]
    fn local_discovery_only_uses_debug_user_wildcard_listeners() {
        let row = |address: &str, state: &str, uid: &str| format!(
            "0: {address}:AFB5 00000000:0000 {state} 00000000:00000000 00:00000000 00000000 {uid} 0 1234");
        assert_eq!(debug_listener_ports(&row("00000000", "0A", "2000")), vec![44981]);
        assert_eq!(debug_listener_ports(&row("00000000000000000000000000000000", "0A", "2000")), vec![44981]);
        for (address, state, uid) in [("0100007F", "0A", "2000"), ("00000000", "01", "2000"),
            ("00000000", "0A", "0"), ("00000000", "0A", "20020238")] {
            assert!(debug_listener_ports(&row(address, state, uid)).is_empty());
        }
        assert!(debug_listener_ports("invalid table").is_empty());
    }

    #[test]
    fn local_discovery_only_accepts_hdc_ports() {
        assert_eq!(parse_port(b"OHOS HDC-45678"), Some(45678));
        for value in [b"OHOS HDC-0".as_slice(), b"OHOS HDC-65536", b"OTHER-45678",
            b"OHOS HDC-45678\n", b"OHOS HDC-45678extra", b"OHOS HDC-22"] {
            assert_eq!(parse_port(value), None);
        }
    }

    #[cfg(any(target_os = "linux", target_env = "ohos"))]
    #[test]
    fn local_discovery_receives_the_daemons_fixed_destination_reply() {
        let daemon = UdpSocket::bind("127.0.0.1:0").unwrap();
        let port = daemon.local_addr().unwrap().port();
        let worker = std::thread::spawn(move || {
            daemon.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
            let mut bytes = [0u8; 256];
            let (length, peer) = daemon.recv_from(&mut bytes).unwrap();
            assert_eq!(&bytes[..length], HANDSHAKE_MESSAGE.as_bytes());
            assert_eq!(peer.ip().to_string(), "127.0.0.2");
            daemon.send_to(b"OHOS HDC-45678", (peer.ip(), port)).unwrap();
        });
        assert_eq!(discover_at(port, Duration::from_secs(1), [127, 0, 0, 2], [127, 0, 0, 1]).unwrap(), Some(45678));
        worker.join().unwrap();
    }
}
