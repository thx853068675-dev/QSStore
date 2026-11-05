//! Auditable in-process HDC TCP host transport for Qingqi.
//!
//! Adapted from Muka Rust HDC (MIT). The application starts an HDC host
//! server on a private loopback port and keeps the RSA host key in its own
//! sandbox. No executable is extracted or launched from a writable directory.

mod auth;
mod client;
mod net_discover;
pub mod local_discover;
mod local_diag;
mod local_tcp;
pub mod lan_scan;
mod lan_sweep;
mod lan_neighbors;
pub use local_discover::{discover_local_port, discover_lan_port, discover_lan_devices};
mod parser;
mod server;
mod transfer;
mod usb;

#[cfg(target_os = "windows")]
mod usb_hotplug_windows;

use std::io::{self, Error, ErrorKind};
use std::path::Path;
use std::sync::Mutex;
use std::time::{Duration, Instant};

static START_LOCK: Mutex<()> = Mutex::new(());
static ACTIVE_PORT: Mutex<Option<u16>> = Mutex::new(None);

// Read-only UI observations never issue another HDC command or wait for the
// install queue. Bytes count successful host transport writes, not bm work.
static INSTALL_PROGRESS: Mutex<Option<std::collections::HashMap<String, (&'static str, u64, u64, Instant)>>> = Mutex::new(None);
fn set_install_progress(path: &str, phase: &'static str, sent: u64, total: u64) {
    if let Ok(mut rows) = INSTALL_PROGRESS.lock() {
        let rows=rows.get_or_insert_with(std::collections::HashMap::new);
        if !rows.contains_key(path) && rows.len() >= 128 {
            if let Some(old)=rows.iter().min_by_key(|(_,row)|row.3).map(|(key,_)|key.clone()) { rows.remove(&old); }
        }
        rows.insert(path.into(),(phase,sent.min(total),total,Instant::now()));
    }
}
pub fn reset_install_progress(path: &str) { set_install_progress(path,"waiting",0,0); }
pub fn report_install_progress(path: &str, phase: &'static str, sent: u64, total: u64) { set_install_progress(path,phase,sent,total); }
pub fn report_observed_file_progress(path: &str, sent: u64, total: u64) {
    if let Ok(mut rows)=INSTALL_PROGRESS.lock() {
        if let Some(row)=rows.as_mut().and_then(|rows|rows.get_mut(path)) { *row=("transfer",sent.min(total),total,Instant::now()); }
    }
}
pub fn install_progress(path: &str) -> (&'static str,u64,u64) {
    INSTALL_PROGRESS.lock().ok().and_then(|rows|rows.as_ref().and_then(|rows|rows.get(path).map(|row|(row.0,row.1,row.2)))).unwrap_or(("waiting",0,0))
}

#[cfg(test)]
mod progress_tests {
    #[test]
    fn parallel_install_observations_are_independent() {
        let a="/sandbox/parallel-a.hap";let b="/sandbox/parallel-b.hap";
        super::reset_install_progress(a);super::reset_install_progress(b);
        super::report_install_progress(a,"transfer",50,100);
        super::report_install_progress(b,"transfer",150,200);
        assert_eq!(super::install_progress(a),("transfer",50,100));
        assert_eq!(super::install_progress(b),("transfer",150,200));
        super::report_observed_file_progress(a,60,100);
        assert_eq!(super::install_progress(b),("transfer",150,200));
    }
    #[test]
    fn transfer_observation_is_bound_to_its_file_and_does_not_invent_bm_percent() {
        super::reset_install_progress("/sandbox/one.hap");
        assert_eq!(super::install_progress("/sandbox/one.hap"), ("waiting", 0, 0));
        super::report_install_progress("/sandbox/one.hap", "transfer", 40, 100);
        assert_eq!(super::install_progress("/sandbox/one.hap"), ("transfer", 40, 100));
        assert_eq!(super::install_progress("/sandbox/other.hap"), ("waiting", 0, 0));
        super::report_observed_file_progress("/sandbox/other.hap", 99, 100);
        assert_eq!(super::install_progress("/sandbox/one.hap"), ("transfer", 40, 100));
        super::report_observed_file_progress("/sandbox/one.hap", 50, 100);
        assert_eq!(super::install_progress("/sandbox/one.hap"), ("transfer", 50, 100));
        super::report_install_progress("/sandbox/one.hap", "installing", 110, 100);
        assert_eq!(super::install_progress("/sandbox/one.hap"), ("installing", 100, 100));
    }
}

/// The running server's tables, kept so callers can drop device links on purpose.
///
/// The device's wireless-debugging daemon effectively serves one host at a time,
/// so holding a link after we are done locks other tools (DevEco Studio, the hdc
/// CLI) out of the device. The protocol has no "disconnect" verb, so releasing a
/// link means dropping its write half here.
static INSTALL_SERVER: std::sync::OnceLock<(server::ConnectMap, server::TcpMap)> =
    std::sync::OnceLock::new();

/// Bind a probe listener to `port`, or to an OS-assigned free port when taken.
///
/// Returns the chosen port. The probe is dropped immediately; it exists to fail
/// fast and to hand the caller a port that is actually free. Binding with
/// SO_REUSEADDR matches what the server itself does, so the probe does not
/// report a port busy that the server could still have taken.
fn choose_free_port(port: u16) -> io::Result<u16> {
    let probe = std::net::TcpListener::bind(("127.0.0.1", port));
    match probe {
        Ok(listener) => {
            if port != 0 {
                return Ok(port);
            }
            let chosen = listener.local_addr()?.port();
            drop(listener);
            Ok(chosen)
        }
        Err(_) => {
            // Preferred port is taken by something else. Fall back to whatever
            // the OS hands out rather than refusing to start.
            if port == 0 {
                return Err(Error::new(ErrorKind::AddrInUse, "no free loopback port"));
            }
            let listener = std::net::TcpListener::bind(("127.0.0.1", 0))?;
            let chosen = listener.local_addr()?.port();
            drop(listener);
            Ok(chosen)
        }
    }
}

/// Start the loopback server, preferring `port` but settling for a free one.
///
/// Returns the port the server actually listens on: the caller must use that
/// value for every later `command` call, since it may differ from the request.
pub fn start(key_root: &Path, port: u16) -> io::Result<u16> {
    let _start=START_LOCK.lock().map_err(|_| Error::other("HDC startup lock poisoned"))?;
    if port < 1024 || !key_root.is_absolute() {
        return Err(Error::new(ErrorKind::InvalidInput, "invalid HDC port or key root"));
    }
    auth::set_key_root(key_root.to_path_buf())?;
    let address = |candidate: u16| format!("127.0.0.1:{candidate}");
    {
        let active = ACTIVE_PORT.lock().map_err(|_| Error::other("HDC lock poisoned"))?;
        if let Some(current) = *active {
            if std::net::TcpStream::connect(address(current)).is_ok() {
                return Ok(current);
            }
        }
    }
    // Preferred port first; if something else holds it, take a free one.
    let chosen = match choose_free_port(port) {
        Ok(free) if free == port => port,
        Ok(free) => {
            tracing::warn!("HDC loopback port {port} is busy, using {free} instead");
            free
        }
        Err(_) => port,
    };
    match start_on(&address(chosen), chosen) {
        Ok(()) => Ok(chosen),
        Err(error) if chosen == port => {
            // Lost the race for the preferred port; retry on an assigned one.
            let fallback = choose_free_port(0)?;
            tracing::warn!("HDC loopback port {port} became busy, using {fallback}");
            start_on(&address(fallback), fallback)?;
            Ok(fallback)
        }
        Err(error) => Err(error),
    }
}

fn start_on(address: &str, port: u16) -> io::Result<()> {
    let mut active = ACTIVE_PORT.lock().map_err(|_| Error::other("HDC lock poisoned"))?;
    let server_address = address.to_string();
    let connect_map = server::ConnectMap::new();
    let tcp_map = server::TcpMap::new();
    // Keep the tables reachable from outside the server thread so `disconnect`
    // can drop device links; set once, the first time the server starts.
    let _ = INSTALL_SERVER.set((connect_map.clone(), tcp_map.clone()));
    std::thread::Builder::new().name("qingqi-hdc-server".into()).spawn(move || {
        if let Ok(runtime) = tokio::runtime::Builder::new_multi_thread()
            .enable_all().worker_threads(2).build()
        {
            let result = runtime.block_on(server::run_embedded_server_mode(&server_address,
                connect_map, tcp_map, server::UsbMap::new()));
            if let Err(error) = result {
                tracing::error!("Qingqi HDC server stopped: {error}");
            }
        }
    })?;
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        if std::net::TcpStream::connect(address).is_ok() {
            *active = Some(port);
            return Ok(());
        }
        std::thread::sleep(Duration::from_millis(60));
    }
    Err(Error::new(ErrorKind::TimedOut, "HDC loopback server did not start"))
}

/// Drop every device link, releasing the device's debug endpoint.
///
/// Used when we are done (and by the manual "disconnect" control), so other
/// tools can reach the device. The server keeps listening; the next command
/// reconnects on its own.
pub fn disconnect() -> io::Result<usize> {
    disconnect_matching(None)
}

/// Reconnecting loopback must leave independently selected LAN peers intact.
pub fn disconnect_target(target: &str) -> io::Result<usize> {
    disconnect_matching(Some(target))
}

fn disconnect_matching(target: Option<&str>) -> io::Result<usize> {
    let Some((connect_map, tcp_map)) = INSTALL_SERVER.get() else {
        return Ok(0);
    };
    let keys = {
        let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build()?;
        runtime.block_on(connect_map.keys()).into_iter()
            .filter(|key| target.map(|value| key == value).unwrap_or(true)).collect::<Vec<_>>()
    };
    if keys.is_empty() {
        return Ok(0);
    }
    let dropped = keys.len();
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build()?;
    runtime.block_on(async {
        for key in keys {
            if let Some(session_id) = connect_map.get_session_id(&key).await {
                tcp_map.end_session(session_id).await;
                connect_map.remove_session(&key,session_id).await;
            }
        }
    });
    Ok(dropped)
}

pub fn command(port: u16, arguments: &[String], timeout: Duration) -> io::Result<String> {
    if arguments.is_empty() {
        return Err(Error::new(ErrorKind::InvalidInput, "empty HDC command"));
    }
    let address = format!("127.0.0.1:{port}");
    let mut argv = vec!["hdc".to_string(), "-p".to_string(),
        "-s".to_string(), address];
    argv.extend(arguments.iter().cloned());
    let parsed = parser::parse_command(argv.into_iter())?;
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build()?;
    runtime.block_on(async {
        tokio::time::timeout(timeout, async {
            let mut client = client::Client::new(&parsed).await?;
            client.handshake().await?;
            client.execute_command().await?;
            Ok(client.take_output())
        }).await.map_err(|_| Error::new(ErrorKind::TimedOut, "HDC command timed out"))?
    })
}
