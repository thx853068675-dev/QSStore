//! Foreground LAN discovery without a companion app. Only HDC's initial
//! unauthenticated greeting is sent; no key, shell, login or install command.
use std::collections::HashMap;
use std::io;
use std::net::{Ipv4Addr, SocketAddr, TcpStream};
use std::sync::{Arc, Mutex, atomic::{AtomicBool, Ordering}};
use std::time::{Duration, Instant};

const MAX_HOSTS: usize = 24;
const MAX_CANDIDATES: usize = 128;
const MAX_SOCKETS: usize = 64;
const SCAN_BUDGET: Duration = Duration::from_secs(30);
const MAX_PORT_HOSTS: usize = 4096;

#[derive(Clone, Default)]
pub struct Snapshot {
    pub devices: Vec<String>,
    pub peers: Vec<String>,
    pub first_peer_ms: Option<u64>,
    pub searching: bool,
    pub checked: usize,
    pub total: usize,
    pub covered: usize,
    pub complete: bool,
    pub error: String,
    pub diagnostic: String,
    pub first_found_ms: Option<u64>,
    pub started: Option<Instant>,
}
struct Scan { id: String, cancel: Arc<AtomicBool>, snapshot: Snapshot }
static CANCELLED:Mutex<std::collections::VecDeque<String>>=Mutex::new(std::collections::VecDeque::new());
static ACTIVE: Mutex<Option<Scan>> = Mutex::new(None);
// A second user-initiated search continues an incomplete range. No automatic
// background sweep, and a changing port never requires the user to type it.
static CURSORS: Mutex<Option<HashMap<Ipv4Addr, u32>>> = Mutex::new(None);
static KNOWN: Mutex<Option<HashMap<Ipv4Addr, u16>>> = Mutex::new(None);
static PORT_PAGES: Mutex<Option<HashMap<String, usize>>> = Mutex::new(None);
static SCAN_WORKER:Mutex<()>=Mutex::new(());
static PROBE_GATE: Mutex<()> = Mutex::new(());
static SOCKET_FAILURE:std::sync::atomic::AtomicI32=std::sync::atomic::AtomicI32::new(0);
static HEALTH_CANCEL:Mutex<Option<Arc<AtomicBool>>>=Mutex::new(None);
pub fn cancel_health(){if let Ok(current)=HEALTH_CANCEL.lock(){if let Some(cancel)=current.as_ref(){cancel.store(true,Ordering::Relaxed);}}}
static HEALTH_CHECKING:std::sync::atomic::AtomicUsize=std::sync::atomic::AtomicUsize::new(0);
static TCP_READY:std::sync::atomic::AtomicUsize=std::sync::atomic::AtomicUsize::new(0);

fn valid_id(id: &str) -> bool {
    (8..=64).contains(&id.len()) && id.bytes().all(|b|b.is_ascii_alphanumeric() || b == b'-')
}
fn allowed(cancel: &AtomicBool, deadline: Instant) -> bool {
    !cancel.load(Ordering::Relaxed) && Instant::now() < deadline
}
fn update(id: &str, action: impl FnOnce(&mut Snapshot)) {
    if let Ok(mut active) = ACTIVE.lock() {
        if let Some(scan) = active.as_mut().filter(|scan|scan.id == id) { action(&mut scan.snapshot); }
    }
}
fn found(id: &str, ip: Ipv4Addr, port: u16) {
    let endpoint = format!("{ip}:{port}");
    update(id, |snapshot| {
        if snapshot.first_found_ms.is_none() {snapshot.first_found_ms=snapshot.started.map(|start|start.elapsed().as_millis() as u64);}
        snapshot.devices.retain(|old|old.split_once(':').map(|v|v.0) != Some(&ip.to_string()));
        if snapshot.devices.len() < MAX_HOSTS { snapshot.devices.push(endpoint); }
    });
    if let Ok(mut known) = KNOWN.lock() {
        let map=known.get_or_insert_with(HashMap::new);
        if map.len()<MAX_HOSTS || map.contains_key(&ip) { map.insert(ip,port); }
    }
}

pub fn snapshot(id: &str) -> io::Result<Snapshot> {
    let active=ACTIVE.lock().map_err(|_|io::Error::other("LAN discovery lock"))?;
    active.as_ref().filter(|scan|scan.id==id).map(|scan|scan.snapshot.clone())
        .ok_or_else(||io::Error::new(io::ErrorKind::NotFound,"LAN search has ended"))
}
pub fn stop(id: &str) {
    if let Ok(mut cancelled)=CANCELLED.lock(){if !cancelled.iter().any(|old|old==id){cancelled.push_back(id.into());while cancelled.len()>128{cancelled.pop_front();}}}
    if let Ok(mut active)=ACTIVE.lock() {
        if let Some(scan)=active.as_mut().filter(|scan|scan.id==id) {
            scan.cancel.store(true,Ordering::Relaxed);scan.snapshot.searching=false;
        }
    }
}
pub fn quiesce() {
    if let Ok(mut active)=ACTIVE.lock() {
        if let Some(scan)=active.as_mut() {scan.cancel.store(true,Ordering::Relaxed);scan.snapshot.searching=false;}
    }
    // A selected-device command must not race the final no-key greeting.
    let _guard=PROBE_GATE.lock();
}

// Only complete neighbours on the real physical LAN are admitted. A MAC
// address is ordering information, never evidence of a phone or an HDC port.
fn neighbors(table: &str, interfaces: &[([u8;4],[u8;4])]) -> Vec<Ipv4Addr> {
    let mut rows=Vec::new();
    for line in table.lines().take(512) {
        let fields:Vec<_>=line.split_whitespace().collect();
        if fields.len()<6 || fields[2]!="0x2" ||
            !(fields[5].starts_with("wlan") || fields[5].starts_with("wifi") ||
              fields[5].starts_with("eth") || fields[5].starts_with("en")) {continue;}
        let Ok(ip)=fields[0].parse::<Ipv4Addr>() else {continue;};
        let mac:Vec<_>=fields[3].split(':').filter_map(|v|u8::from_str_radix(v,16).ok()).collect();
        if mac.len()!=6 || mac.iter().all(|v|*v==0) || mac[0]&1!=0 {continue;}
        let octets=ip.octets();
        if !ip.is_private() || !interfaces.iter().any(|(local,mask)| {
            let remote=u32::from_be_bytes(octets);let own=u32::from_be_bytes(*local);let mask=u32::from_be_bytes(*mask);
            remote!=own && remote&mask==own&mask && remote!=own&mask && remote!=(own|!mask)
        }) {continue;}
        if !rows.iter().any(|(_,old)|*old==ip) {rows.push((mac[0]&2!=0,ip));}
    }
    // Phones commonly use private WLAN MACs. All other valid neighbours remain
    // eligible, and only a protocol response can put one in the visible list.
    rows.sort_by_key(|(private,_)|!private);
    // A busy router's neighbour table is larger than our visible device list.
    // Keep those addresses for a single-port lookup; blind port sweeps still
    // truncate explicitly to MAX_HOSTS below.
    rows.into_iter().take(512).map(|(_,ip)|ip).collect()
}

fn neighbor_candidates(interfaces:&[([u8;4],[u8;4])],cancel:&AtomicBool,deadline:Instant,arp_loader:impl FnOnce()->String)->(Vec<Ipv4Addr>,usize,String){
    let mut table=std::fs::read_to_string("/proc/net/arp").unwrap_or_default();
    let mut peers=neighbors(&table,interfaces);let mut source=String::from("proc");
    if allowed(cancel,deadline){
        match crate::lan_neighbors::table(cancel,deadline){
            Ok(value)=>{for peer in neighbors(&value,interfaces){if !peers.contains(&peer){peers.push(peer);}}table=value;source="kernel".into();},
            Err(error) if peers.is_empty()=>{source=format!("kernel-unavailable:{}",error.raw_os_error().unwrap_or(0));},
            Err(_)=>{}
        }
    }
    if peers.is_empty()&&allowed(cancel,deadline){
        let fallback=arp_loader();let rows=neighbors(&fallback,interfaces);
        if !rows.is_empty(){table=fallback;peers=rows;source="local-link".into();}
    }
    (peers,table.lines().count(),source)
}

#[cfg(test)]
fn verify(mut stream: TcpStream, ip: Ipv4Addr, port: u16, cancel: &AtomicBool, deadline: Instant) -> bool {
    verify_wait(&mut stream,ip,port,cancel,deadline,Duration::from_millis(120))
}
pub(super) fn verify_wait(stream:&mut TcpStream,ip:Ipv4Addr,port:u16,cancel:&AtomicBool,deadline:Instant,wait:Duration)->bool {
    let _guard=loop{
        if !allowed(cancel,deadline){return false;}
        match PROBE_GATE.try_lock(){Ok(guard)=>break guard,Err(std::sync::TryLockError::WouldBlock)=>std::thread::sleep(Duration::from_millis(5)),Err(_)=>return false}
    };
    if !allowed(cancel,deadline) {return false;}
    crate::local_tcp::daemon_reply_at(stream,SocketAddr::from((ip,port)),
        deadline.min(Instant::now()+wait)).unwrap_or(false)
}

#[cfg(unix)]
fn connect_targets_wait(targets: &[(Ipv4Addr,u16)], cancel: &AtomicBool, deadline: Instant, wait:Duration) -> Vec<(Ipv4Addr,u16,TcpStream)> {
    connect_targets_capacity(targets,cancel,deadline,wait,MAX_SOCKETS).streams
}
#[derive(Default)]
pub(super) struct ConnectBatch {
    pub streams:Vec<(Ipv4Addr,u16,TcpStream)>,pub attempted:usize,pub complete:bool,pub timed_out:usize,pub peak:usize,pub error:i32,
}
#[cfg(unix)]
fn probe_socket()->io::Result<std::os::fd::OwnedFd>{
    use std::os::fd::{AsRawFd,FromRawFd};
    let fd=unsafe{libc::socket(libc::AF_INET,libc::SOCK_STREAM,0)};
    if fd<0{return Err(io::Error::last_os_error());}
    let socket=unsafe{std::os::fd::OwnedFd::from_raw_fd(fd)};
    if unsafe{libc::fcntl(socket.as_raw_fd(),libc::F_SETFL,libc::O_NONBLOCK)}<0{return Err(io::Error::last_os_error());}
    unsafe{libc::fcntl(fd,libc::F_SETFD,libc::FD_CLOEXEC);}
    Ok(socket)
}
#[cfg(unix)]
pub(super) fn connect_targets_capacity(targets: &[(Ipv4Addr,u16)], cancel: &AtomicBool, deadline: Instant, wait:Duration,capacity:usize) -> ConnectBatch {
    use std::os::fd::{AsRawFd,FromRawFd,IntoRawFd,OwnedFd};
    let mut pending=Vec::new();
    let mut result=ConnectBatch::default();
    let interfaces=crate::local_discover::lan_interfaces();
    for &(ip,port) in targets.iter().take(capacity.min(256)) {
        if !allowed(cancel,deadline) {break;}
        let local=interfaces.iter().find(|(local,mask)|
            u32::from_be_bytes(ip.octets())&u32::from_be_bytes(*mask)==u32::from_be_bytes(*local)&u32::from_be_bytes(*mask)).map(|v|v.0);
        let socket=match probe_socket(){Ok(socket)=>socket,Err(error)=>{result.error=error.raw_os_error().unwrap_or(0);break;}};
        let fd=socket.as_raw_fd();
        let mut addr:libc::sockaddr_in=unsafe{std::mem::zeroed()};
        addr.sin_family=libc::AF_INET as libc::sa_family_t;addr.sin_port=port.to_be();
        addr.sin_addr.s_addr=u32::from_ne_bytes(ip.octets());
        #[cfg(any(target_os="macos",target_os="ios"))]
        {addr.sin_len=std::mem::size_of_val(&addr) as u8;}
        if let Some(local)=local {
            let mut source=addr;source.sin_port=0;source.sin_addr.s_addr=u32::from_ne_bytes(local);
            if unsafe{libc::bind(fd,&source as *const _ as *const libc::sockaddr,std::mem::size_of_val(&source) as libc::socklen_t)}<0 {
                result.error=io::Error::last_os_error().raw_os_error().unwrap_or(0);SOCKET_FAILURE.store(result.error,Ordering::Relaxed);break;
            }
        }
        let status=unsafe{libc::connect(fd,&addr as *const _ as *const libc::sockaddr,std::mem::size_of_val(&addr) as libc::socklen_t)};
        let error=io::Error::last_os_error().raw_os_error().unwrap_or(0);
        result.attempted+=1;
        if status==0 || error==libc::EINPROGRESS {pending.push((ip,port,local,socket));}
        else {
            SOCKET_FAILURE.store(error,Ordering::Relaxed);
            if matches!(error,libc::ENOMEM|libc::ENOBUFS|libc::EADDRNOTAVAIL|libc::EMFILE|libc::ENFILE){result.error=error;break;}

        }
    }
    result.peak=pending.len();
    let mut events:Vec<libc::pollfd>=pending.iter().map(|(_,_,_,socket)|libc::pollfd{fd:socket.as_raw_fd(),events:libc::POLLOUT,revents:0}).collect();
    let batch_deadline=deadline.min(Instant::now()+wait);
    let mut pending:Vec<_>=pending.into_iter().map(|(ip,port,local,socket)|(ip,port,local,Some(socket))).collect();
    let mut connected=Vec::new();
    while !events.is_empty() && events.iter().any(|event|event.fd>=0) && allowed(cancel,batch_deadline) {
        let wait=batch_deadline.saturating_duration_since(Instant::now()).as_millis().min(20) as i32;
        for (index,chunk) in events.chunks_mut(64).enumerate(){
            let count=unsafe{libc::poll(chunk.as_mut_ptr(),chunk.len() as libc::nfds_t,if index==0{wait.min(10)}else{0})};
            if count<0&&io::Error::last_os_error().kind()!=io::ErrorKind::Interrupted{result.error=io::Error::last_os_error().raw_os_error().unwrap_or(0);break;}
        }
        if result.error!=0 {break;}
        for ((ip,port,local,socket),event) in pending.iter_mut().zip(events.iter_mut()) {
            if event.fd<0 || event.revents==0 {continue;}
            let Some(socket)=socket.take() else {continue;};
            event.fd=-1;
            let mut error:libc::c_int=0;let mut size=std::mem::size_of_val(&error) as libc::socklen_t;
            let status=unsafe{libc::getsockopt(socket.as_raw_fd(),libc::SOL_SOCKET,libc::SO_ERROR,&mut error as *mut _ as *mut _,&mut size)};
            if status==0 && error==0 {
                TCP_READY.fetch_add(1,Ordering::Relaxed);
                let stream=unsafe{TcpStream::from_raw_fd(socket.into_raw_fd())};
                if local.is_some_and(|source|stream.local_addr().ok().map(|address|address.ip())!=Some(std::net::IpAddr::V4(Ipv4Addr::from(source)))){
                    result.error=libc::ENETUNREACH;
                }else if stream.set_nonblocking(false).is_ok() {connected.push((*ip,*port,stream));}
            }else if status==0 {drop(socket);}
            else{result.error=io::Error::last_os_error().raw_os_error().unwrap_or(-1);}
        }
    }
    result.timed_out=events.iter().filter(|event|event.fd>=0).count();
    drop(pending);
    result.complete=result.attempted==targets.len()&&result.error==0&&allowed(cancel,deadline);
    result.streams=connected;result
}
#[cfg(not(unix))]
fn connect_targets_wait(_:&[(Ipv4Addr,u16)],_:&AtomicBool,_:Instant,_:Duration)->Vec<(Ipv4Addr,u16,TcpStream)>{Vec::new()}
#[cfg(not(unix))]
pub(super) fn connect_targets_capacity(_:&[(Ipv4Addr,u16)],_:&AtomicBool,_:Instant,_:Duration,_:usize)->ConnectBatch{ConnectBatch::default()}

fn connect_batch_wait(ip:Ipv4Addr,ports:&[u16],cancel:&AtomicBool,deadline:Instant,wait:Duration)->Vec<(u16,TcpStream)>{
    let targets:Vec<_>=ports.iter().take(MAX_SOCKETS).map(|port|(ip,*port)).collect();
    connect_targets_wait(&targets,cancel,deadline,wait).into_iter().map(|(_,port,stream)|(port,stream)).collect()
}

fn port_host_allowed(ip:Ipv4Addr,interfaces:&[([u8;4],[u8;4])])->bool{
    let remote=u32::from(ip);
    ip.is_private()&&!interfaces.iter().any(|(local,_)|u32::from_be_bytes(*local)==remote)&&
        interfaces.iter().any(|(local,mask)|{
            let own=u32::from_be_bytes(*local);let mask=u32::from_be_bytes(*mask);
            remote&mask==own&mask&&remote!=(own&mask)&&remote!=(own|!mask)
        })
}
fn port_priority(interfaces:&[([u8;4],[u8;4])],known:Vec<Ipv4Addr>)->Vec<Ipv4Addr>{
    let mut result=Vec::new();let mut seen=std::collections::HashSet::new();
    for ip in known.into_iter().take(512){if port_host_allowed(ip,interfaces)&&seen.insert(ip){result.push(ip);}}
    // Keep the common /24 fast path first, with every physical interface
    // represented. A larger actual subnet is expanded only if this misses.
    for &(local,mask) in interfaces{
        let own=u32::from_be_bytes(local);let mask=u32::from_be_bytes(mask);let slice_mask=mask|0xffffff00;
        let first=own&slice_mask;let last=first|!slice_mask;
        for host in first.saturating_add(1)..last{
            let ip=Ipv4Addr::from(host);
            if port_host_allowed(ip,interfaces)&&seen.insert(ip){result.push(ip);}
        }
    }
    result
}
fn port_candidates_at(interfaces:&[([u8;4],[u8;4])],known:Vec<Ipv4Addr>,offset:usize)->Vec<Ipv4Addr>{
    let mut result=port_priority(interfaces,known);
    let mut seen:std::collections::HashSet<_>=result.iter().copied().collect();
    let ranges:Vec<_>=interfaces.iter().map(|(local,mask)|{
        let mask=u32::from_be_bytes(*mask);(u32::from_be_bytes(*local)&mask,(!mask).saturating_sub(1))
    }).collect();
    // Round-robin the real subnets. Large enterprise networks are paged only
    // on a new user request; no unbounded or background subnet sweep.
    for step in 0..ranges.iter().map(|(_,count)|*count as usize).max().unwrap_or(0){
        for &(first,count) in &ranges{
            if step>=count as usize||count==0{continue;}
            let host=first+1+((offset as u64+step as u64)%count as u64) as u32;
            let ip=Ipv4Addr::from(host);
            if port_host_allowed(ip,interfaces)&&seen.insert(ip){result.push(ip);}
            if result.len()>=MAX_PORT_HOSTS{return result;}
        }
    }
    result
}
fn port_candidates(interfaces:&[([u8;4],[u8;4])],known:Vec<Ipv4Addr>)->Vec<Ipv4Addr>{
    let key=format!("{interfaces:?}");
    let offset=PORT_PAGES.lock().ok().map(|mut pages|{
        let map=pages.get_or_insert_with(HashMap::new);
        if map.len()>=8&&!map.contains_key(&key){map.clear();}
        let offset=map.entry(key).or_default();let value=*offset;
        *offset=offset.saturating_add(MAX_PORT_HOSTS-1280);value
    }).unwrap_or(0);
    port_candidates_at(interfaces,known,offset)
}

#[cfg(test)]
fn connect_batch(ip:Ipv4Addr,ports:&[u16],cancel:&AtomicBool,deadline:Instant)->Vec<(u16,TcpStream)>{
    // Let exact-device health checks finish before starting another blind scan wave.
    while HEALTH_CHECKING.load(Ordering::Relaxed)>0 && allowed(cancel,deadline){
        std::thread::sleep(Duration::from_millis(5));
    }
    connect_batch_wait(ip,ports,cancel,deadline,Duration::from_millis(120))
}

/// A remembered port is only a hint. Recheck the unauthenticated system banner
/// before returning it; scoped commands will still verify the expected UDID.
pub fn known_port(ip: Ipv4Addr) -> Option<u16> {
    let port=KNOWN.lock().ok().and_then(|map|map.as_ref().and_then(|map|map.get(&ip).copied()))?;
    let cancel=AtomicBool::new(false);
    let deadline=Instant::now()+Duration::from_millis(1200);
    connect_batch_wait(ip,&[port],&cancel,deadline,Duration::from_millis(300)).into_iter()
        .find_map(|(port,mut stream)|verify_wait(&mut stream,ip,port,&cancel,deadline,Duration::from_millis(700)).then_some(port))
}

fn probe_hints(targets:&[(Ipv4Addr,u16)],cancel:&AtomicBool,deadline:Instant)->Vec<(Ipv4Addr,u16)>{
    let deadline=deadline.min(Instant::now()+Duration::from_secs(3));
    // Remembered offline devices share one connect window instead of costing
    // one timeout each. No authentication is sent, even to remembered hosts.
    connect_targets_wait(targets,cancel,deadline,Duration::from_millis(250)).into_iter()
        .filter_map(|(ip,port,mut stream)|verify_wait(&mut stream,ip,port,cancel,deadline,Duration::from_millis(500)).then_some((ip,port))).collect()
}

/// Liveness only: never send a greeting or replace an authenticated HDC session.
fn endpoint_reachable(address:&SocketAddr)->bool {
    TcpStream::connect_timeout(address,Duration::from_millis(180)).is_ok()
}
pub struct EndpointHealth {
    pub endpoint:String,
    pub reachable:bool,
    pub first_error:String,
    pub retried:bool,
    pub elapsed_ms:u128,
}
struct HealthPriority;
impl HealthPriority{fn enter()->Self{HEALTH_CHECKING.fetch_add(1,Ordering::Relaxed);Self}}
impl Drop for HealthPriority{fn drop(&mut self){HEALTH_CHECKING.fetch_sub(1,Ordering::Relaxed);}}
fn probe_endpoint(endpoint:&str,address:&SocketAddr)->EndpointHealth{probe_endpoint_cancelled(endpoint,address,&AtomicBool::new(false))}
fn probe_endpoint_cancelled(endpoint:&str,address:&SocketAddr,cancel:&AtomicBool)->EndpointHealth{
    let started=Instant::now();
    if cancel.load(Ordering::Relaxed){return EndpointHealth{endpoint:endpoint.into(),reachable:false,first_error:"cancelled".into(),retried:false,elapsed_ms:0};}
    let first=TcpStream::connect_timeout(address,Duration::from_millis(180));
    let (reachable,first_error,retried)=match first{
        Ok(_)=>(true,String::new(),false),
        Err(error)=>{
            // One missed Wi-Fi wakeup or a VPN route change is not proof of offline.
            // Drain existing scan sockets, then retry the exact endpoint on the physical LAN source.
            std::thread::sleep(Duration::from_millis(80));
            let retry=match address{
                SocketAddr::V4(v4)=>!connect_batch_wait(*v4.ip(),&[v4.port()],cancel,
                    Instant::now()+Duration::from_millis(800),Duration::from_millis(800)).is_empty(),
                _=>false,
            };
            (retry,error.to_string(),true)
        }
    };
    EndpointHealth{endpoint:endpoint.into(),reachable,first_error,retried,elapsed_ms:started.elapsed().as_millis()}
}
pub fn probe_endpoints(endpoints:Vec<String>)->io::Result<Vec<EndpointHealth>>{
    if endpoints.len()>MAX_HOSTS{return Err(io::Error::other("too many heartbeat endpoints"));}
    let mut addresses=Vec::new();
    for endpoint in endpoints{
        let address:SocketAddr=endpoint.parse().map_err(|_|io::Error::other("invalid heartbeat endpoint"))?;
        let SocketAddr::V4(v4)=address else{return Err(io::Error::other("heartbeat requires IPv4"));};
        if !v4.ip().is_private()||v4.port()<10000{return Err(io::Error::other("heartbeat requires a private debug endpoint"));}
        if !addresses.iter().any(|(_,old)|*old==address){addresses.push((endpoint,address));}
    }
    if addresses.is_empty(){return Ok(Vec::new());}
    let interfaces=crate::local_discover::lan_interfaces();
    if interfaces.is_empty(){return Err(io::Error::new(io::ErrorKind::NotConnected,"physical LAN unavailable"));}
    addresses.retain(|(_,address)|{
        let SocketAddr::V4(v4)=address else{return false;};
        interfaces.iter().any(|(local,mask)|{
            let remote=u32::from_be_bytes(v4.ip().octets());let own=u32::from_be_bytes(*local);let mask=u32::from_be_bytes(*mask);
            remote!=own&&remote&mask==own&mask&&remote!=(own|!mask)
        })
    });
    let cancel=Arc::new(AtomicBool::new(false));
    if let Ok(mut current)=HEALTH_CANCEL.lock(){if let Some(old)=current.replace(cancel.clone()){old.store(true,Ordering::Relaxed);}}
    let _priority=HealthPriority::enter();let mut results=Vec::new();
    for batch in addresses.chunks(8){
        if cancel.load(Ordering::Relaxed){return Err(io::Error::new(io::ErrorKind::Interrupted,"heartbeat cancelled"));}
        std::thread::scope(|scope|{
            let workers:Vec<_>=batch.iter().map(|(endpoint,address)|scope.spawn({let cancel=&cancel;move||probe_endpoint_cancelled(endpoint,address,cancel)})).collect();
            for worker in workers{if let Ok(row)=worker.join(){results.push(row);}}
        });
    }
    if cancel.load(Ordering::Relaxed){return Err(io::Error::new(io::ErrorKind::Interrupted,"heartbeat cancelled"));}
    Ok(results)
}
pub fn reachable_endpoints(endpoints:Vec<String>)->io::Result<Vec<String>>{
    Ok(probe_endpoints(endpoints)?.into_iter().filter_map(|row|row.reachable.then_some(row.endpoint)).collect())
}

pub fn start(id: &str, fallback_arp: String) -> io::Result<()> {
    start_with_loader(id,move||fallback_arp)
}
pub fn start_with_loader(id: &str, arp_loader: impl FnOnce()->String+Send+'static) -> io::Result<()> {
    start_with_hints(id,Vec::new(),arp_loader)
}
pub fn start_with_hints(id: &str, hints:Vec<String>, arp_loader: impl FnOnce()->String+Send+'static) -> io::Result<()> {
    start_with_options(id,hints,SCAN_BUDGET,true,arp_loader)
}
pub fn start_with_options(id:&str,hints:Vec<String>,budget:Duration,deep:bool,arp_loader:impl FnOnce()->String+Send+'static)->io::Result<()>{
    start_with_port_options(id,hints,budget,deep,None,arp_loader)
}
pub fn start_with_port_options(id:&str,hints:Vec<String>,budget:Duration,deep:bool,exact_port:Option<u16>,arp_loader:impl FnOnce()->String+Send+'static)->io::Result<()>{
    start_with_target_options(id,hints,budget,deep,exact_port,None,arp_loader)
}
pub fn start_with_target_options(id:&str,hints:Vec<String>,budget:Duration,deep:bool,exact_port:Option<u16>,exact_host:Option<Ipv4Addr>,arp_loader:impl FnOnce()->String+Send+'static)->io::Result<()>{
    if !valid_id(id) {return Err(io::Error::new(io::ErrorKind::InvalidInput,"invalid LAN search id"));}
    if exact_port.is_some_and(|port|port<10000){return Err(io::Error::new(io::ErrorKind::InvalidInput,"five-digit port required"));}
    if exact_host.is_some_and(|ip|!ip.is_private()) {return Err(io::Error::new(io::ErrorKind::InvalidInput,"private LAN address required"));}
    let mut active=ACTIVE.lock().map_err(|_|io::Error::other("LAN discovery lock"))?;
    if CANCELLED.lock().map_err(|_|io::Error::other("LAN cancellation lock"))?.iter().any(|old|old==id){return Err(io::Error::new(io::ErrorKind::Interrupted,"LAN request was cancelled"));}
    if let Some(scan)=active.as_ref() {scan.cancel.store(true,Ordering::Relaxed);}
    let cancel=Arc::new(AtomicBool::new(false));
    SOCKET_FAILURE.store(0,Ordering::Relaxed);TCP_READY.store(0,Ordering::Relaxed);
    *active=Some(Scan{id:id.into(),cancel:cancel.clone(),snapshot:Snapshot{searching:true,started:Some(Instant::now()),..Snapshot::default()}});
    let id=id.to_owned();
    std::thread::spawn(move||{
        let deadline=Instant::now()+budget.min(SCAN_BUDGET);
        // Only one scan executor may broadcast or open probe sockets. Replaced
        // requests exit before work; sockets from the old executor drain first.
        let _worker=loop{
            if !allowed(&cancel,deadline){update(&id,|s|s.searching=false);return;}
            match SCAN_WORKER.try_lock(){Ok(guard)=>break guard,Err(std::sync::TryLockError::WouldBlock)=>std::thread::sleep(Duration::from_millis(5)),Err(_)=>return}
        };
        #[cfg(unix)]
        let interfaces=crate::local_discover::lan_interfaces();
        #[cfg(not(unix))]
        let interfaces=Vec::new();
        if interfaces.is_empty() {update(&id,|s|{s.error="请连接 Wi-Fi 后重试".into();s.searching=false;});return;}
        if exact_host.is_some_and(|ip|!port_host_allowed(ip,&interfaces)) {
            update(&id,|s|{s.error="设备不在当前局域网".into();s.searching=false;});return;
        }
        if let Some(port)=exact_port{
            let (mut known,rows,source)=neighbor_candidates(&interfaces,&cancel,deadline,arp_loader);
            for hint in hints{
                if let Some((host,_))=hint.split_once(':'){if let Ok(ip)=host.parse(){known.insert(0,ip);}}
            }
            let priority=port_priority(&interfaces,known.clone());
            let candidates=port_candidates(&interfaces,known);
            update(&id,|s|{s.total=candidates.len();s.diagnostic=format!("fixed_port={port}; candidates={}; arp_rows={rows}; source={source}",candidates.len());});
            let mut any_found=false;
            let first_deadline=deadline.min(Instant::now()+Duration::from_secs(24));
            for group in [&candidates[..priority.len()],&candidates[priority.len()..]]{
                for batch in group.chunks(MAX_SOCKETS){
                    if !allowed(&cancel,first_deadline){break;}
                    let targets:Vec<_>=batch.iter().map(|ip|(*ip,port)).collect();
                    for (ip,port,mut stream) in connect_targets_wait(&targets,&cancel,first_deadline,Duration::from_millis(300)){
                        if verify_wait(&mut stream,ip,port,&cancel,first_deadline,Duration::from_millis(800)){
                            found(&id,ip,port);any_found=true;
                        }
                    }
                    update(&id,|s|s.checked+=batch.len());
                }
                if any_found{break;}
            }
            // A sleeping/loaded phone may miss the short first SYN or greeting.
            // Retry only the bounded priority set, never another full port scan.
            if !any_found{
                for batch in priority.chunks(MAX_SOCKETS){
                    if !allowed(&cancel,deadline){break;}
                    let targets:Vec<_>=batch.iter().map(|ip|(*ip,port)).collect();
                    for (ip,port,mut stream) in connect_targets_wait(&targets,&cancel,deadline,Duration::from_millis(650)){
                        if verify_wait(&mut stream,ip,port,&cancel,deadline,Duration::from_millis(1500)){found(&id,ip,port);}
                    }
                }
            }
            update(&id,|s|{s.searching=false;s.diagnostic.push_str(&format!("; tcp_ready={}; connect_errno={}",TCP_READY.load(Ordering::Relaxed),SOCKET_FAILURE.load(Ordering::Relaxed)));});return;
        }
        // Persisted authenticated endpoints are only hints: revalidate their
        // current no-key HDC greeting and physical subnet before publishing.
        let mut hint_hosts=Vec::new();let mut hint_targets=Vec::new();
        for hint in hints.into_iter().take(MAX_HOSTS) {
            if !allowed(&cancel,deadline){break;}
            let Some((host,port))=hint.split_once(':') else {continue;};
            let (Ok(ip),Ok(port))=(host.parse::<Ipv4Addr>(),port.parse::<u16>()) else {continue;};
            if port<10000 || !interfaces.iter().any(|(local,mask)| {
                let remote=u32::from_be_bytes(ip.octets());let own=u32::from_be_bytes(*local);let mask=u32::from_be_bytes(*mask);
                remote!=own && remote&mask==own&mask && remote!=own&mask && remote!=(own|!mask)
            }) {continue;}
            if exact_host.is_some_and(|selected|selected!=ip){continue;}
            if !hint_hosts.contains(&ip) {hint_hosts.push(ip);}
            if !hint_targets.contains(&(ip,port)){hint_targets.push((ip,port));}
        }
        for (ip,port) in probe_hints(&hint_targets,&cancel,deadline){found(&id,ip,port);}
        if !allowed(&cancel,deadline){update(&id,|s|s.searching=false);return;}
        if let Ok(devices)=if exact_host.is_none(){crate::local_discover::discover_lan_devices_cancelled(&cancel,deadline)}else{Ok(Vec::new())} {
            for endpoint in devices {
                if !allowed(&cancel,deadline){break;}
                if let Some((host,port))=endpoint.split_once(':') {
                    if let (Ok(ip),Ok(port))=(host.parse(),port.parse()) {found(&id,ip,port);}
                }
            }
        }
        if !allowed(&cancel,deadline) {update(&id,|s|s.searching=false);return;}
        // Read after UDP primed ARP, not before. New peers must also be found
        // when this phone had never talked to them before this search.
        let (mut peers,arp_rows,source)=if let Some(host)=exact_host{(vec![host],0,String::from("selected-ip"))}
            else{neighbor_candidates(&interfaces,&cancel,deadline,arp_loader)};
        for ip in hint_hosts.into_iter().rev() {peers.retain(|peer|*peer!=ip);peers.insert(0,ip);}
        let omitted=peers.len().saturating_sub(MAX_CANDIDATES);peers.truncate(MAX_CANDIDATES);
        // Publish IPs before either discovery transport finishes. TCP fallback
        // belongs to this same automatic session, not the manual-entry sheet.
        update(&id,|s|{
            s.peers=peers.iter().map(|ip|ip.to_string()).collect();
            s.first_peer_ms=s.started.map(|start|start.elapsed().as_millis()as u64);
            s.total=peers.len()*if deep{55536}else{1};
            s.diagnostic=format!("automatic_tcp={deep}; candidates={}; omitted={omitted}; arp_rows={arp_rows}; source={source}",peers.len());
        });
        let queries=crate::local_discover::discover_peer_ports_cancelled(&peers,&cancel,deadline,|endpoint|{
            if let Some((host,port))=endpoint.split_once(':'){
                if let (Ok(ip),Ok(port))=(host.parse(),port.parse()){found(&id,ip,port);}
            }
        }).unwrap_or(0);
        update(&id,|s|s.diagnostic.push_str(&format!("; directed_udp_queries={queries}")));
        if !deep {
            update(&id,|s|{
                s.checked=peers.len();s.covered=peers.len();s.complete=omitted==0&&!cancel.load(Ordering::Relaxed);s.searching=false;
                if peers.is_empty()&&s.devices.is_empty(){s.error="未发现局域网设备".into();}
            });return;
        }
        if peers.is_empty() {update(&id,|s|s.error="未发现局域网设备".into());}
        if !allowed(&cancel,deadline){update(&id,|s|s.searching=false);return;}
        let known=snapshot(&id).map(|s|s.devices).unwrap_or_default();
        let hosts:Vec<_>=peers.into_iter().map(|ip|{

            let cursor=CURSORS.lock().ok().and_then(|map|map.as_ref().and_then(|map|map.get(&ip).copied())).unwrap_or(10000);
            let mut host=crate::lan_sweep::Host::new(ip,cursor);
            host.found=known.iter().find_map(|endpoint|endpoint.split_once(':').filter(|(name,_)|*name==ip.to_string()).and_then(|(_,port)|port.parse().ok()));host
        }).collect();
        let mut hosts=hosts;
        let result=crate::lan_sweep::run_parallel(&mut hosts,&cancel,deadline,10000,65535,
            |ip,port|found(&id,ip,port),|row|{
                update(&id,|s|{s.checked=row.checked;s.covered=row.covered;s.complete=row.complete&&omitted==0;});
            });
        // A SYN burst can finish before a waking daemon's greeting arrives.
        // Retry only ports which actually completed TCP, after the broad probe
        // sockets have drained. An open port alone is never an HDC device.
        let mut retried=0;
        for host in &mut hosts {
            if host.found.is_some(){continue;}
            for &port in &host.open_ports {
                if !allowed(&cancel,deadline){break;}
                for _ in 0..2 {
                    if !allowed(&cancel,deadline){break;}
                    retried+=1;
                    let streams=connect_batch_wait(host.ip,&[port],&cancel,deadline,Duration::from_millis(650));
                    let valid=streams.into_iter().any(|(_,mut stream)|verify_wait(&mut stream,host.ip,port,&cancel,deadline,Duration::from_millis(1500)));
                    if valid{host.found=Some(port);found(&id,host.ip,port);break;}
                }
                if host.found.is_some(){break;}
            }
        }
        if let Ok(mut cursors)=CURSORS.lock(){let map=cursors.get_or_insert_with(HashMap::new);for host in &hosts{if map.len()<MAX_CANDIDATES||map.contains_key(&host.ip){map.insert(host.ip,host.next);}}}
        update(&id,|s|{
            s.searching=false;
            s.diagnostic.push_str(&format!("; shared_queue=true; complete={}; covered={}; timed_out={}; peak_sockets={}; socket_limit={}; omitted_hosts={}; connect_errno={}; created={}; elapsed_ms={}; tcp_open={}; protocol_failures={}; host_coverage={:?}",
                s.complete,result.covered,result.timed_out,result.peak_sockets,result.socket_limit,omitted,result.error,
                result.created,result.elapsed_ms,
                result.tcp_open,result.protocol_failures,
                hosts.iter().map(|host|(host.ip,host.checked,host.timed_out,host.found,host.next)).collect::<Vec<_>>()));
            s.diagnostic.push_str(&format!("; post_sweep_retries={retried}; open_candidates={:?}",hosts.iter().filter(|host|!host.open_ports.is_empty()).map(|host|(host.ip,&host.open_ports)).collect::<Vec<_>>()));
            if !s.complete&&!cancel.load(Ordering::Relaxed)&&s.error.is_empty(){s.error="扫描未全部完成，可重新查找继续".into();}
        });
    });
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn exact_port_search_covers_the_real_slash_23_not_just_the_local_slash_24(){
        let rows=port_candidates(&[([192,168,2,20],[255,255,254,0])],Vec::new());
        assert!(rows.contains(&Ipv4Addr::new(192,168,3,163)),"same physical LAN peer must not require an explicit IP");
        assert!(!rows.contains(&Ipv4Addr::new(192,168,2,20)));
        assert!(!rows.contains(&Ipv4Addr::new(192,168,4,8)));
        assert_eq!(rows.iter().collect::<std::collections::HashSet<_>>().len(),rows.len());
    }
    #[test]
    fn exact_port_candidates_keep_neighbors_beyond_the_visible_device_limit(){
        let table=(1..=40).map(|n|format!("192.168.4.{n} 0x1 0x2 e2:11:22:33:44:55 * wlan0\n")).collect::<String>();
        let rows=neighbors(&table,&[([192,168,3,20],[255,255,0,0])]);
        assert_eq!(rows.len(),40,"discovery candidates are not limited to the 24 visible devices");
    }
    #[test]
    fn wide_network_pages_are_bounded_and_do_not_starve_other_interfaces(){
        let interfaces=[([192,168,3,20],[255,255,0,0]),([10,4,3,8],[255,255,255,0])];
        let first=port_candidates_at(&interfaces,vec![Ipv4Addr::new(192,168,90,8)],0);
        let next=port_candidates_at(&interfaces,Vec::new(),MAX_PORT_HOSTS-1280);
        assert_eq!(first.len(),MAX_PORT_HOSTS);assert_eq!(next.len(),MAX_PORT_HOSTS);
        assert_eq!(first[0],Ipv4Addr::new(192,168,90,8));
        assert!(first.contains(&Ipv4Addr::new(10,4,3,163)));
        assert!(next.iter().any(|ip|!first.contains(ip)));
        assert!(first.iter().all(|ip|port_host_allowed(*ip,&interfaces)));
        assert!(!first.contains(&Ipv4Addr::new(192,168,3,20)));
        assert!(!first.contains(&Ipv4Addr::new(10,4,3,8)));
    }
    #[test]
    fn exact_port_probe_accepts_a_loaded_daemon_reply_after_the_old_120ms_cutoff(){
        use hdc_protocol::config::{get_version,HdcCommand,TaskMessage,HANDSHAKE_MESSAGE};
        use hdc_protocol::serializer::{concat_pack,unpack_payload_head,HdcSerialize,SessionHandShake,HEAD_SIZE};
        use std::io::{Read,Write};
        let listener=std::net::TcpListener::bind("127.0.0.1:0").unwrap();let port=listener.local_addr().unwrap().port();
        let worker=std::thread::spawn(move||{
            let (mut stream,_)=listener.accept().unwrap();let mut header=[0;HEAD_SIZE];stream.read_exact(&mut header).unwrap();
            let fields=unpack_payload_head(&header).unwrap();let mut body=vec![0;fields.head_size as usize+fields.data_size as usize];
            stream.read_exact(&mut body).unwrap();
            std::thread::sleep(Duration::from_millis(300));
            let reply=SessionHandShake{banner:HANDSHAKE_MESSAGE.into(),auth_type:2,session_id:1,connect_key:String::new(),buf:"challenge".into(),version:get_version()};
            stream.write_all(&concat_pack(&TaskMessage{channel_id:0,command:HdcCommand::KernelHandshake,payload:reply.serialize()})).unwrap();
        });
        let mut stream=TcpStream::connect((Ipv4Addr::LOCALHOST,port)).unwrap();
        assert!(verify_wait(&mut stream,Ipv4Addr::LOCALHOST,port,&AtomicBool::new(false),Instant::now()+Duration::from_secs(2),Duration::from_millis(800)));
        worker.join().unwrap();
    }
    #[test]
    fn remembered_targets_connect_in_one_batch_and_never_send_authentication(){
        use hdc_protocol::config::{get_version,HdcCommand,TaskMessage,HANDSHAKE_MESSAGE};
        use hdc_protocol::serializer::{concat_pack,unpack_payload_head,unpack_task_message,HdcDeserialize,HdcSerialize,SessionHandShake,HEAD_SIZE};
        use std::io::{Read,Write};
        let accepted=Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let mut targets=Vec::new();let mut workers=Vec::new();
        for _ in 0..2{
            let listener=std::net::TcpListener::bind("127.0.0.1:0").unwrap();
            targets.push((Ipv4Addr::LOCALHOST,listener.local_addr().unwrap().port()));
            let accepted=accepted.clone();
            workers.push(std::thread::spawn(move||{
                let (mut stream,_)=listener.accept().unwrap();accepted.fetch_add(1,Ordering::SeqCst);
                let deadline=Instant::now()+Duration::from_secs(1);
                while accepted.load(Ordering::SeqCst)<2&&Instant::now()<deadline{std::thread::sleep(Duration::from_millis(2));}
                assert_eq!(accepted.load(Ordering::SeqCst),2,"the next endpoint must not wait for this one's reply");
                stream.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
                let mut head=[0;HEAD_SIZE];stream.read_exact(&mut head).unwrap();
                let size=unpack_payload_head(&head).unwrap();let mut frame=head.to_vec();frame.resize(HEAD_SIZE+size.head_size as usize+size.data_size as usize,0);
                stream.read_exact(&mut frame[HEAD_SIZE..]).unwrap();let request=unpack_task_message(&frame).unwrap();
                let greeting=SessionHandShake::deserialize(&request.payload).unwrap();assert_eq!(greeting.auth_type,0);assert!(greeting.buf.is_empty());
                let reply=SessionHandShake{banner:HANDSHAKE_MESSAGE.into(),auth_type:2,session_id:1,connect_key:String::new(),buf:"challenge".into(),version:get_version()};
                stream.write_all(&concat_pack(&TaskMessage{channel_id:0,command:HdcCommand::KernelHandshake,payload:reply.serialize()})).unwrap();
            }));
        }
        let found=probe_hints(&targets,&AtomicBool::new(false),Instant::now()+Duration::from_secs(2));
        for worker in workers{worker.join().unwrap();}
        assert_eq!(found.len(),2);
        let listener=std::net::TcpListener::bind("127.0.0.1:0").unwrap();listener.set_nonblocking(true).unwrap();
        assert!(probe_hints(&[(Ipv4Addr::LOCALHOST,listener.local_addr().unwrap().port())],&AtomicBool::new(true),Instant::now()+Duration::from_secs(1)).is_empty());
        assert!(listener.accept().is_err());
    }
    #[test]
    fn a_stop_before_delayed_native_start_cannot_resurrect_the_request() {
        let id="power-cancel-before-start";
        stop(id);
        let result=start_with_options(id,Vec::new(),Duration::from_secs(10),true,||panic!("cancelled request must not read ARP"));
        assert_eq!(result.unwrap_err().kind(),io::ErrorKind::Interrupted);
    }
    #[test]
    fn cancelled_udp_discovery_opens_no_socket_or_broadcast() {
        let started=Instant::now();
        let rows=crate::local_discover::discover_lan_devices_cancelled(&AtomicBool::new(true),Instant::now()+Duration::from_secs(10)).unwrap();
        assert!(rows.is_empty());assert!(started.elapsed()<Duration::from_millis(250));
    }
    #[test]
    fn cancelled_health_does_not_connect_or_retry() {
        let reservation=std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        reservation.set_nonblocking(true).unwrap();
        let address=reservation.local_addr().unwrap();
        let row=probe_endpoint_cancelled(&address.to_string(),&address,&AtomicBool::new(true));
        assert!(!row.reachable);assert!(!row.retried);assert!(reservation.accept().is_err());
    }
    #[test]
    fn heartbeat_detects_a_closed_port_without_sending_authentication_or_protocol_bytes() {
        use std::io::Read;
        let listener=std::net::TcpListener::bind("127.0.0.1:0").unwrap();let address=listener.local_addr().unwrap();
        let worker=std::thread::spawn(move||{
            let (mut stream,_)=listener.accept().unwrap();stream.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
            let mut bytes=[0;1];assert_eq!(stream.read(&mut bytes).unwrap(),0);
        });
        assert!(endpoint_reachable(&address));worker.join().unwrap();
        assert!(!endpoint_reachable(&address));
    }
    #[test]
    fn heartbeat_retry_recovers_a_waking_listener_without_sending_bytes() {
        use std::io::Read;
        let reservation=std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let address=reservation.local_addr().unwrap();drop(reservation);
        let worker=std::thread::spawn(move||{
            std::thread::sleep(Duration::from_millis(40));
            let listener=std::net::TcpListener::bind(address).unwrap();
            listener.set_nonblocking(true).unwrap();
            let deadline=Instant::now()+Duration::from_secs(2);
            loop{
                match listener.accept(){
                    Ok((mut stream,_))=>{
                        stream.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
                        let mut bytes=[0;1];assert_eq!(stream.read(&mut bytes).unwrap(),0);break;
                    },
                    Err(error) if error.kind()==io::ErrorKind::WouldBlock&&Instant::now()<deadline=>std::thread::sleep(Duration::from_millis(5)),
                    Err(error)=>panic!("retry did not reach waking listener: {error}"),
                }
            }
        });
        let result=probe_endpoint(&address.to_string(),&address);
        worker.join().unwrap();
        assert!(result.reachable);assert!(result.retried);assert!(!result.first_error.is_empty());
        assert!(result.elapsed_ms<1500);
    }
    #[test]
    fn heartbeat_retry_keeps_a_closed_port_offline_with_a_bounded_wait() {
        let listener=std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let address=listener.local_addr().unwrap();drop(listener);
        let result=probe_endpoint(&address.to_string(),&address);
        assert!(!result.reachable);assert!(result.retried);assert!(!result.first_error.is_empty());
        assert!(result.elapsed_ms<1500);
    }
    #[test]
    fn heartbeat_rejects_public_invalid_and_unbounded_endpoints_before_network_access() {
        for endpoint in ["8.8.8.8:54321","192.168.3.8:9999","::1:54321","192.168.3.8:65536","not-an-endpoint"] {
            assert!(reachable_endpoints(vec![endpoint.into()]).is_err());
        }
        assert!(reachable_endpoints(vec!["192.168.3.8:54321".into();25]).is_err());
    }
    #[test]
    fn neighbors_stay_in_real_lan_and_exclude_vpn_self_incomplete_and_invalid_macs() {
        let table="IP address HW type Flags HW address Mask Device\n192.168.3.8 0x1 0x2 e2:11:22:33:44:55 * wlan0\n192.168.3.9 0x1 0x2 00:11:22:33:44:55 * wlan0\n192.168.3.20 0x1 0x2 e2:11:22:33:44:55 * wlan0\n192.168.3.10 0x1 0x0 e2:11:22:33:44:55 * wlan0\n192.168.4.8 0x1 0x2 e2:11:22:33:44:55 * wlan0\n192.168.3.11 0x1 0x2 e2:11:22:33:44:55 * vpn-tun\n192.168.3.12 0x1 0x2 01:11:22:33:44:55 * wlan0";
        assert_eq!(neighbors(table,&[([192,168,3,20],[255,255,255,0])]),vec!["192.168.3.8".parse::<Ipv4Addr>().unwrap(),"192.168.3.9".parse().unwrap()]);
    }
    #[test]
    fn an_open_non_hdc_port_is_not_a_device_and_cancel_opens_no_connections() {
        use std::io::Write;
        let listener=std::net::TcpListener::bind("127.0.0.1:0").unwrap();let port=listener.local_addr().unwrap().port();
        let worker=std::thread::spawn(move||{let (mut stream,_)=listener.accept().unwrap();stream.write_all(b"HTTP/1.1 200 OK\r\n").unwrap();});
        let deadline=Instant::now()+Duration::from_secs(1);
        let rows=connect_batch(Ipv4Addr::LOCALHOST,&[port],&AtomicBool::new(false),deadline);
        assert_eq!(rows.len(),1);for (_,stream) in rows {assert!(!verify(stream,Ipv4Addr::LOCALHOST,port,&AtomicBool::new(false),deadline));}worker.join().unwrap();
        assert!(connect_batch(Ipv4Addr::LOCALHOST,&[port],&AtomicBool::new(true),deadline).is_empty());
    }
}
