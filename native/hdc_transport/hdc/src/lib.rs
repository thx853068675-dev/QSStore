//! Auditable in-process HDC TCP host transport for Qingqi.
//!
//! Adapted from Muka Rust HDC (MIT). The application starts an HDC host
//! server on a private loopback port and keeps the RSA host key in its own
//! sandbox. No executable is extracted or launched from a writable directory.

mod auth;
mod client;
mod net_discover;
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

static ACTIVE_PORT: Mutex<Option<u16>> = Mutex::new(None);

// Read-only UI observations never issue another HDC command or wait for the
// install queue. Bytes count successful host transport writes, not bm work.
static INSTALL_PROGRESS: Mutex<Option<(String, &'static str, u64, u64)>> = Mutex::new(None);

pub fn reset_install_progress(path: &str) {
    if let Ok(mut row) = INSTALL_PROGRESS.lock() {
        *row = Some((path.into(), "waiting", 0, 0));
    }
}

pub fn report_install_progress(path: &str, phase: &'static str, sent: u64, total: u64) {
    if let Ok(mut row) = INSTALL_PROGRESS.lock() {
        *row = Some((path.into(), phase, sent.min(total), total));
    }
}

pub fn report_observed_file_progress(path: &str, sent: u64, total: u64) {
    if let Ok(mut row) = INSTALL_PROGRESS.lock() {
        if let Some((current, phase, received, size)) = row.as_mut() {
            if current == path {
                *phase = "transfer";
                *received = sent.min(total);
                *size = total;
            }
        }
    }
}

pub fn install_progress(path: &str) -> (&'static str, u64, u64) {
    if let Ok(row) = INSTALL_PROGRESS.lock() {
        if let Some((current, phase, sent, total)) = row.as_ref() {
            if current == path { return (*phase, *sent, *total); }
        }
    }
    ("waiting", 0, 0)
}

#[cfg(test)]
mod progress_tests {
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
            let result = runtime.block_on(server::run_server_mode(&server_address,
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
    let Some((connect_map, tcp_map)) = INSTALL_SERVER.get() else {
        return Ok(0);
    };
    let keys = {
        let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build()?;
        runtime.block_on(connect_map.get_list(true))
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
            }
            connect_map.remove(&key).await;
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
