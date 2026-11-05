//! Read-only neighbour enumeration when an app cannot read /proc/net/arp.
use std::io;
use std::sync::atomic::{AtomicBool,Ordering};
use std::time::{Duration,Instant};

fn record(body:&[u8])->Option<(u32,[u8;4],[u8;6])>{
    if body.len()<12||body[0]!=2{return None;}
    let state=u16::from_ne_bytes(body[8..10].try_into().ok()?);
    if state&0xde==0||state&0x21!=0{return None;}
    let index=u32::from_ne_bytes(body[4..8].try_into().ok()?);
    let(mut ip,mut mac)=(None,None);let mut offset=12;
    while offset+4<=body.len(){
        let size=u16::from_ne_bytes(body[offset..offset+2].try_into().ok()?) as usize;
        if size<4||offset+size>body.len(){return None;}
        let kind=u16::from_ne_bytes(body[offset+2..offset+4].try_into().ok()?);
        let value=&body[offset+4..offset+size];
        if kind==1&&value.len()==4{ip=Some(value.try_into().ok()?);}
        if kind==2&&value.len()==6{mac=Some(value.try_into().ok()?);}
        offset+=(size+3)&!3;
    }
    Some((index,ip?,mac?))
}

pub fn table(cancel:&AtomicBool,deadline:Instant)->io::Result<String>{
    #[cfg(any(target_os="linux",target_env="ohos"))]{
        use std::os::fd::{AsRawFd,FromRawFd,OwnedFd};
        let fd=unsafe{libc::socket(libc::AF_NETLINK,libc::SOCK_DGRAM|libc::SOCK_CLOEXEC,0)};
        if fd<0{return Err(io::Error::last_os_error());}
        let socket=unsafe{OwnedFd::from_raw_fd(fd)};
        let mut kernel:libc::sockaddr_nl=unsafe{std::mem::zeroed()};kernel.nl_family=libc::AF_NETLINK as libc::sa_family_t;
        let mut request=[0u8;28];request[..4].copy_from_slice(&28u32.to_ne_bytes());
        request[4..6].copy_from_slice(&30u16.to_ne_bytes()); // RTM_GETNEIGH
        request[6..8].copy_from_slice(&0x301u16.to_ne_bytes()); // REQUEST | DUMP
        request[8..12].copy_from_slice(&1u32.to_ne_bytes());request[16]=libc::AF_INET as u8;
        let sent=unsafe{libc::sendto(socket.as_raw_fd(),request.as_ptr() as *const _,request.len(),0,
            &kernel as *const _ as *const libc::sockaddr,std::mem::size_of_val(&kernel) as libc::socklen_t)};
        if sent<0{return Err(io::Error::last_os_error());}
        let deadline=deadline.min(Instant::now()+Duration::from_millis(200));
        let mut result=String::from("IP address HW type Flags HW address Mask Device\n");let mut rows=0;
        while !cancel.load(Ordering::Relaxed)&&Instant::now()<deadline&&rows<512{
            let mut poll=libc::pollfd{fd:socket.as_raw_fd(),events:libc::POLLIN,revents:0};
            if unsafe{libc::poll(&mut poll,1,10)}<=0{continue;}
            let mut bytes=[0u8;32768];let mut source:libc::sockaddr_nl=unsafe{std::mem::zeroed()};
            let mut length=std::mem::size_of_val(&source) as libc::socklen_t;
            let size=unsafe{libc::recvfrom(socket.as_raw_fd(),bytes.as_mut_ptr() as *mut _,bytes.len(),libc::MSG_DONTWAIT,
                &mut source as *mut _ as *mut libc::sockaddr,&mut length)};
            if size<0{return Err(io::Error::last_os_error());}if source.nl_pid!=0{continue;}
            let mut offset=0;
            while offset+16<=size as usize{
                let count=u32::from_ne_bytes(bytes[offset..offset+4].try_into().unwrap()) as usize;
                if count<16||offset+count>size as usize{return Err(io::Error::other("invalid neighbour response"));}
                if u32::from_ne_bytes(bytes[offset+8..offset+12].try_into().unwrap())==1{
                    let body=&bytes[offset+16..offset+count];
                    match u16::from_ne_bytes(bytes[offset+4..offset+6].try_into().unwrap()){
                        3=>return Ok(result),
                        2 if body.len()>=4=>{let error=i32::from_ne_bytes(body[..4].try_into().unwrap());if error<0{return Err(io::Error::from_raw_os_error(-error));}},
                        28=>if let Some((index,ip,mac))=record(body){
                            let mut name=[0 as libc::c_char;libc::IF_NAMESIZE];
                            if !unsafe{libc::if_indextoname(index,name.as_mut_ptr())}.is_null(){
                                let name=unsafe{std::ffi::CStr::from_ptr(name.as_ptr())}.to_string_lossy();
                                result.push_str(&format!("{} 0x1 0x2 {:02x}:{:02x}:{:02x}:{:02x}:{:02x}:{:02x} * {}\n",
                                    std::net::Ipv4Addr::from(ip),mac[0],mac[1],mac[2],mac[3],mac[4],mac[5],name));rows+=1;
                            }
                        },
                        _=>{}
                    }
                }
                offset+=(count+3)&!3;
            }
        }
        if cancel.load(Ordering::Relaxed){return Err(io::Error::new(io::ErrorKind::Interrupted,"neighbour read cancelled"));}
        Err(io::Error::new(io::ErrorKind::TimedOut,"neighbour read timed out"))
    }
    #[cfg(not(any(target_os="linux",target_env="ohos")))]{
        let _=(cancel,deadline);Err(io::Error::new(io::ErrorKind::Unsupported,"neighbour API unavailable"))
    }
}

#[cfg(test)]mod tests{
    use super::*;
    fn sample()->Vec<u8>{
        let mut row=vec![0;12];row[0]=2;row[4..8].copy_from_slice(&4u32.to_ne_bytes());row[8..10].copy_from_slice(&4u16.to_ne_bytes());
        row.extend_from_slice(&[8,0,1,0,192,168,3,8]);row.extend_from_slice(&[10,0,2,0,2,3,4,5,6,7,0,0]);row
    }
    #[test]fn accepts_complete_ipv4_and_rejects_incomplete_failed_or_truncated_records(){
        let mut row=sample();assert_eq!(record(&row),Some((4,[192,168,3,8],[2,3,4,5,6,7])));
        for state in [0u16,1,32]{row[8..10].copy_from_slice(&state.to_ne_bytes());assert_eq!(record(&row),None);}
        row=sample();row[0]=10;assert_eq!(record(&row),None);
        row=sample();assert_eq!(record(&row[..25]),None);row[12..14].copy_from_slice(&1u16.to_ne_bytes());assert_eq!(record(&row),None);
    }
}
