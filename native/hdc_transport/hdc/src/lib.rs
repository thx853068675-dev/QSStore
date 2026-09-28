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

pub fn start(key_root: &Path, port: u16) -> io::Result<()> {
    if port < 1024 || !key_root.is_absolute() {
        return Err(Error::new(ErrorKind::InvalidInput, "invalid HDC port or key root"));
    }
    auth::set_key_root(key_root.to_path_buf())?;
    let address = format!("127.0.0.1:{port}");
    let mut active = ACTIVE_PORT.lock().map_err(|_| Error::other("HDC lock poisoned"))?;
    if *active == Some(port) && std::net::TcpStream::connect(&address).is_ok() {
        return Ok(());
    }
    let server_address = address.clone();
    std::thread::Builder::new().name("qingqi-hdc-server".into()).spawn(move || {
        if let Ok(runtime) = tokio::runtime::Builder::new_multi_thread()
            .enable_all().worker_threads(2).build()
        {
            let result = runtime.block_on(server::run_server_mode(&server_address,
                server::ConnectMap::new(), server::TcpMap::new(), server::UsbMap::new()));
            if let Err(error) = result {
                tracing::error!("Qingqi HDC server stopped: {error}");
            }
        }
    })?;
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        if std::net::TcpStream::connect(&address).is_ok() {
            *active = Some(port);
            return Ok(());
        }
        std::thread::sleep(Duration::from_millis(60));
    }
    Err(Error::new(ErrorKind::TimedOut, "HDC loopback server did not start"))
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
