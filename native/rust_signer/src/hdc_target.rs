use std::{cell::RefCell, net::Ipv4Addr, sync::Mutex};

pub static COMMAND_LOCK: Mutex<()> = Mutex::new(());
static PEER_LOCKS: Mutex<Option<std::collections::HashMap<String, std::sync::Arc<Mutex<()>>>>> = Mutex::new(None);
pub fn peer_lock(target: &str) -> Result<std::sync::Arc<Mutex<()>>, String> {
    private_endpoint(target)?;
    let mut locks = PEER_LOCKS.lock().map_err(|_| "HDC peer locks poisoned")?;
    let map = locks.get_or_insert_with(std::collections::HashMap::new);
    if !map.contains_key(target) && map.len() >= 24 {
        map.retain(|_, lock| std::sync::Arc::strong_count(lock) > 1);
        if map.len() >= 24 { return Err("Too many active devices".into()); }
    }
    Ok(map.entry(target.into()).or_insert_with(|| std::sync::Arc::new(Mutex::new(()))).clone())
}
static LOCAL_TARGET: Mutex<Option<String>> = Mutex::new(None);
thread_local! { static SELECTED: RefCell<Option<String>> = const { RefCell::new(None) }; }

pub struct Request {
    pub target: String,
    pub udid: String,
    pub operation: u32,
    pub parameter: String,
}

pub fn private_endpoint(target: &str) -> Result<(), String> {
    let (address, port) = target.split_once(':').ok_or("invalid LAN device address")?;
    let ip: Ipv4Addr = address.parse().map_err(|_| "invalid LAN device address")?;
    let port: u16 = port.parse().map_err(|_| "invalid LAN device port")?;
    let last=ip.octets()[3];
    if !ip.is_private() || port < 10000 || last==0 || last==255 || format!("{ip}:{port}") != target {
        return Err("LAN device requires a private IPv4 address and five-digit port".into());
    }
    Ok(())
}
pub fn request(text: &str) -> Result<Request,String> {
    let value:serde_json::Value=serde_json::from_str(text).map_err(|_|"invalid device request")?;
    let row=Request{
        target:value["target"].as_str().ok_or("missing device address")?.to_string(),
        udid:value.get("udid").map(|v|v.as_str().ok_or("invalid device identity")).transpose()?.unwrap_or_default().to_string(),
        operation:u32::try_from(value["operation"].as_u64().ok_or("invalid device operation")?).map_err(|_|"invalid device operation")?,
        parameter:value.get("parameter").map(|v|v.as_str().ok_or("invalid device parameter")).transpose()?.unwrap_or_default().to_string(),
    };
    private_endpoint(&row.target)?;
    if !matches!(row.operation,1|2|3|4|5|6|7|10|11|12|13|14|16|22) ||
      row.parameter.len()>4096 || (!row.udid.is_empty() &&
      (!(40..=128).contains(&row.udid.len()) || !row.udid.bytes().all(|b|b.is_ascii_hexdigit()))) {
        return Err("invalid scoped device operation".into());
    }
    Ok(row)
}
pub struct Scope;
impl Scope {
    pub fn enter(target: Option<String>) -> Self {
        SELECTED.with(|row| *row.borrow_mut()=target);
        Scope
    }
}
impl Drop for Scope { fn drop(&mut self){ SELECTED.with(|row|*row.borrow_mut()=None); } }
pub fn remember_local(target: &str) {
    if let Ok(mut row)=LOCAL_TARGET.lock(){*row=Some(target.into());}
}
pub fn local() -> Option<String> { LOCAL_TARGET.lock().ok().and_then(|row|row.clone()) }
pub fn arguments(args: &[String]) -> Vec<String> {
    if matches!(args.first().map(String::as_str),Some("tconn"|"list")) {return args.to_vec();}
    let target=SELECTED.with(|row|row.borrow().clone()).or_else(local);
    if let Some(target)=target {
        let mut scoped=vec!["-t".into(),target]; scoped.extend_from_slice(args); scoped
    } else { let mut scoped=vec!["-t".into(),"127.0.0.1:0".into()]; scoped.extend_from_slice(args); scoped }
}

#[cfg(test)] mod tests {
    use super::*;
    #[test] fn peers_use_independent_locks_and_thread_local_targets() {
        let a=peer_lock("192.168.1.8:54321").unwrap();
        let same=peer_lock("192.168.1.8:54321").unwrap();
        let b=peer_lock("192.168.1.9:54321").unwrap();
        let _guard=a.lock().unwrap();assert!(same.try_lock().is_err());assert!(b.try_lock().is_ok());
        let workers:Vec<_>=["192.168.1.8:54321","192.168.1.9:54321"].into_iter().map(|endpoint|std::thread::spawn(move||{
            let _scope=Scope::enter(Some(endpoint.into()));
            assert_eq!(arguments(&["shell".into(),"bm".into()])[1],endpoint);
        })).collect();for worker in workers {worker.join().unwrap();}
    }
    #[test] fn only_private_five_digit_endpoints() {
        for value in ["192.168.1.8:10000","10.0.0.9:65535","172.16.1.2:54321"] {assert!(private_endpoint(value).is_ok());}
        for value in ["8.8.8.8:12345","127.0.0.1:12345","192.168.1.8:9999","192.168.1.8:65536",
          "192.168.1.8:012345","192.168.1.255:12345","192.168.1.8:12345;reboot","localhost:12345"] {assert!(private_endpoint(value).is_err());}
    }
    #[test] fn scope_pins_all_helper_commands_and_cannot_change_port_or_self_delete() {
        let _scope=Scope::enter(Some("192.168.1.9:54321".into()));
        assert_eq!(arguments(&["shell".into(),"bm".into()]),vec!["-t","192.168.1.9:54321","shell","bm"]);
        assert_eq!(arguments(&["tconn".into(),"192.168.1.9:54321".into()]),vec!["tconn","192.168.1.9:54321"]);
        for op in [8,9,15,17,18,19,20,21] {assert!(request(&format!(r#"{{"target":"192.168.1.9:54321","operation":{op}}}"#)).is_err());}
    }
}
