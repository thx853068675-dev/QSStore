//! HDC host client mode.

use crate::parser::ParsedCommand;
use crate::server;
use hdc_protocol::config::{get_version, HdcCommand, HANDSHAKE_MESSAGE, BANNER_SIZE, KEY_MAX_SIZE};

#[cfg(target_os = "windows")]
use windows_sys::Win32::System::Console::{
    GetConsoleMode, GetStdHandle, SetConsoleMode, ReadConsoleInputW, INPUT_RECORD, KEY_EVENT,
    KEY_EVENT_RECORD, STD_INPUT_HANDLE, ENABLE_ECHO_INPUT, ENABLE_LINE_INPUT,
    ENABLE_PROCESSED_INPUT, ENABLE_VIRTUAL_TERMINAL_INPUT,
};
use std::io::{self, Error, ErrorKind};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tracing::{debug, error, warn};

pub struct Client {
    command: HdcCommand,
    params: Vec<String>,
    connect_key: String,
    wr: Option<tokio::net::tcp::OwnedWriteHalf>,
    rd: Option<tokio::net::tcp::OwnedReadHalf>,
    output: String,
}

impl Client {
    pub async fn new(parsed_cmd: &ParsedCommand) -> io::Result<Self> {
        let command = parsed_cmd.command.ok_or_else(|| {
            Error::new(ErrorKind::InvalidInput, "command is None")
        })?;
        let connect_key = crate::parser::auto_connect_key(&parsed_cmd.connect_key, command);

        let stream = TcpStream::connect(&parsed_cmd.server_addr).await.map_err(|e| {
            Error::new(ErrorKind::Other, format!("Connect to server failed: {e}"))
        })?;

        let (rd, wr) = stream.into_split();

        Ok(Self {
            command,
            params: parsed_cmd.parameters.clone(),
            connect_key,
            wr: Some(wr),
            rd: Some(rd),
            output: String::new(),
        })
    }

    pub fn take_output(&mut self) -> String {
        std::mem::take(&mut self.output)
    }

    pub async fn handshake(&mut self) -> io::Result<()> {
        let recv = self.recv().await?;
        let msg = std::str::from_utf8(&recv[..HANDSHAKE_MESSAGE.len()])
            .map_err(|e| Error::new(ErrorKind::InvalidData, format!("handshake from_utf8 error: {e}")))?;

        if msg != HANDSHAKE_MESSAGE {
            return Err(Error::new(ErrorKind::InvalidData, "Recv server-hello failed"));
        }

        let mut buf = Vec::with_capacity(BANNER_SIZE + KEY_MAX_SIZE);
        buf.extend_from_slice(HANDSHAKE_MESSAGE.as_bytes());
        buf.extend_from_slice(&vec![0u8; BANNER_SIZE - HANDSHAKE_MESSAGE.len()]);
        buf.extend_from_slice(self.connect_key.as_bytes());
        buf.extend_from_slice(&vec![0u8; KEY_MAX_SIZE - self.connect_key.len()]);

        self.send(&buf).await;
        Ok(())
    }

    async fn send(&mut self, buf: &[u8]) {
        debug!("channel send buf: {:?}", buf);
        let msg = [&(buf.len() as u32).to_be_bytes()[..], buf].concat();
        if let Some(wr) = &mut self.wr {
            if let Err(e) = wr.write_all(&msg).await {
                warn!("send failed: {e}");
            }
        }
    }

    async fn recv(&mut self) -> io::Result<Vec<u8>> {
        debug!("channel recv buf");
        let len_bytes = self.read_exact_bytes(4, true).await?;
        let expected_size = u32::from_be_bytes([len_bytes[0], len_bytes[1], len_bytes[2], len_bytes[3]]) as usize;
        self.read_exact_bytes(expected_size, false).await
    }

    async fn read_exact_bytes(&mut self, size: usize, frame_boundary: bool) -> io::Result<Vec<u8>> {
        let rd = self.rd.as_mut().ok_or_else(|| Error::new(ErrorKind::Other, "stream closed"))?;
        let mut buf = vec![0u8; size];
        let mut read = 0;
        while read < size {
            match rd.read(&mut buf[read..]).await {
                Ok(0) => return Err(if frame_boundary && read == 0 {
                    Error::new(ErrorKind::ConnectionAborted, "peer closed")
                } else {
                    Error::new(ErrorKind::UnexpectedEof, "peer closed during response frame")
                }),
                Ok(n) => read += n,
                Err(e) => return Err(e),
            }
        }
        Ok(buf)
    }

    pub async fn execute_command(&mut self) -> io::Result<()> {
        let entire_cmd = self.params.join(" ");
        debug!("execute command params: {entire_cmd}");

        match self.command {
            HdcCommand::KernelTargetList
            | HdcCommand::KernelTargetConnect
            | HdcCommand::UnityHilog
            | HdcCommand::KernelTargetDiscover
            | HdcCommand::KernelCheckDevice
            | HdcCommand::KernelEnableKeepalive => self.general_task().await,
            HdcCommand::FileInit | HdcCommand::FileCheck | HdcCommand::FileRecvInit => {
                self.file_send_task().await
            }
            HdcCommand::AppInit => self.app_install_task().await,
            HdcCommand::AppUninstall => self.app_uninstall_task().await,
            HdcCommand::UnityRunmode
            | HdcCommand::UnityReboot
            | HdcCommand::UnityRemount => {
                // Official RunMode: 'tmode' without an argument is rejected client-side.
                if self.command == HdcCommand::UnityRunmode && self.params.len() < 2 {
                    return Err(Error::new(ErrorKind::Other, "Error input parameter"));
                }
                self.unity_task().await
            }
            HdcCommand::KernelTargetReconnect => self.unity_task().await,
            HdcCommand::UnityRootrun => self.unity_root_run_task().await,
            HdcCommand::UnityExecute | HdcCommand::UnityExecuteEx => self.shell_task().await,
            HdcCommand::KernelWaitFor => self.wait_task().await,
            HdcCommand::UnityBugreportInit => self.bug_report_task().await,
            HdcCommand::AppSideload => self.app_sideload_task().await,
            HdcCommand::FlashdUpdateInit
            | HdcCommand::FlashdFlashInit
            | HdcCommand::FlashdErase
            | HdcCommand::FlashdFormat => self.flashd_task().await,
            HdcCommand::ForwardInit
            | HdcCommand::ForwardRportInit
            | HdcCommand::ForwardList
            | HdcCommand::ForwardRportList
            | HdcCommand::ForwardRemove
            | HdcCommand::ForwardRportRemove => self.forward_task().await,
            HdcCommand::JdwpList | HdcCommand::JdwpTrack => self.jdwp_task().await,
            HdcCommand::KernelCheckServer => self.check_server_task().await,
            HdcCommand::ClientVersion => self.version_task().await,
            HdcCommand::KernelHelp => {
                println!("{}", crate::parser::usage());
                Ok(())
            }
            HdcCommand::SpawnSub => {
                self.send(self.params.join(" ").as_bytes()).await;
                self.loop_recv().await
            }
            _ => Err(Error::new(
                ErrorKind::Other,
                format!("unknown command: {}", self.command as u32),
            )),
        }
    }

    async fn unity_task(&mut self) -> io::Result<()> {
        self.send(self.params.join(" ").as_bytes()).await;
        self.loop_recv().await
    }

    async fn wait_task(&mut self) -> io::Result<()> {
        self.send(self.params.join(" ").as_bytes()).await;
        self.loop_recv_waitfor().await
    }

    async fn unity_root_run_task(&mut self) -> io::Result<()> {
        if self.params.len() >= 2 && self.params[1].starts_with("-r") {
            self.params[1] = "r".to_string();
        }
        self.send(self.params.join(" ").as_bytes()).await;
        self.loop_recv().await
    }

    async fn jdwp_task(&mut self) -> io::Result<()> {
        self.send(self.params.join(" ").as_bytes()).await;
        self.loop_recv().await
    }

    async fn shell_task(&mut self) -> io::Result<()> {
        if self.params.len() == 1 {
            // Interactive shell
            self.send(b"shell\0").await;
            let rd = self.rd.take().ok_or_else(|| Error::new(ErrorKind::Other, "stream closed"))?;
            let wr = self.wr.take().ok_or_else(|| Error::new(ErrorKind::Other, "stream closed"))?;
            return interactive_shell_loop(rd, wr).await;
        }
        let cmd = self.params.join(" ");
        self.send(cmd.as_bytes()).await;
        self.loop_recv().await
    }

    async fn forward_task(&mut self) -> io::Result<()> {
        if (self.command == HdcCommand::ForwardRemove || self.command == HdcCommand::ForwardRportRemove)
            && self.params.len() < 2
        {
            return Err(Error::new(ErrorKind::InvalidInput, "Too few arguments."));
        }
        if (self.command == HdcCommand::ForwardInit || self.command == HdcCommand::ForwardRportInit)
            && self.params.len() < 3
        {
            return Err(Error::new(ErrorKind::InvalidInput, "Too few arguments."));
        }
        self.send(self.params.join(" ").as_bytes()).await;
        self.loop_recv().await
    }

    async fn general_task(&mut self) -> io::Result<()> {
        self.send(self.params.join(" ").as_bytes()).await;
        loop {
            let recv = match self.recv().await {
                Ok(recv) => recv,
                Err(error) if error.kind() == ErrorKind::ConnectionAborted => return Ok(()),
                Err(error) => return Err(error),
            };
            match String::from_utf8(recv) {
                Ok(msg) => self.output.push_str(&msg),
                Err(err) => return Err(Error::new(ErrorKind::InvalidData, format!("recv data to str failed: {err}"))),
            }
        }
    }

    async fn bug_report_task(&mut self) -> io::Result<()> {
        if self.params.len() <= 1 {
            return self.general_task().await;
        }
        self.send(self.params.join(" ").as_bytes()).await;
        let mut file = tokio::fs::File::create(self.params[1].as_str()).await?;
        loop {
            let recv = self.recv().await?;
            tokio::io::AsyncWriteExt::write_all(&mut file, &recv).await?;
        }
    }

    async fn file_send_task(&mut self) -> io::Result<()> {
        let mut params = self.params.clone();
        // Only insert -cwd for file send (host needs to resolve local relative paths).
        // For file recv, the remote path is on the device and should remain absolute.
        if self.command == HdcCommand::FileInit {
            let command_field_count = 2;
            let current_dir = std::env::current_dir()?;
            let s = format!("{}{}", current_dir.display(), std::path::MAIN_SEPARATOR);
            params.insert(command_field_count, "-cwd".to_string());
            params.insert(command_field_count + 1, s);
        }
        self.send(params.join(" ").as_bytes()).await;
        self.loop_recv().await
    }

    async fn loop_recv(&mut self) -> io::Result<()> {
        loop {
            match self.recv().await {
                Ok(recv) => {
                    match String::from_utf8(recv.clone()) {
                        Ok(msg) => self.output.push_str(&msg),
                        Err(_) => {
                            // Non-UTF8 data (e.g., binary exit codes from KernelChannelClose)
                            // Channel-close payloads are binary status, not UI text.
                        }
                    }
                }
                Err(e) => {
                    if e.kind() == ErrorKind::ConnectionAborted {
                        return Ok(());
                    }
                    return Err(e);
                }
            }
        }
    }

    async fn loop_recv_waitfor(&mut self) -> io::Result<()> {
        loop {
            match self.recv().await {
                Ok(recv) => {
                    if let HdcCommand::KernelWaitFor = self.command {
                        let wait_for = "[Fail]No any connected target\r\n".to_string();
                        if wait_for == String::from_utf8(recv).expect("invalid UTF-8") {
                            self.send(self.params.join(" ").as_bytes()).await;
                            tokio::time::sleep(tokio::time::Duration::from_millis(1000)).await;
                        } else {
                            std::process::exit(0);
                        }
                    }
                }
                Err(e) => return Err(e),
            }
        }
    }

    async fn app_install_task(&mut self) -> io::Result<()> {
        let mut params = self.params.clone();
        let command_field_count = 1;
        let current_dir = std::env::current_dir()?;
        let s = format!("{}{}", current_dir.display(), std::path::MAIN_SEPARATOR);
        params.insert(command_field_count, "-cwd".to_string());
        params.insert(command_field_count + 1, s);

        self.send(params.join(" ").as_bytes()).await;
        self.loop_recv().await
    }

    async fn app_uninstall_task(&mut self) -> io::Result<()> {
        self.send(self.params.join(" ").as_bytes()).await;
        // The daemon closes the command channel after replying. Preserve that
        // reply for callers; a clean EOF is not an uninstall failure.
        self.loop_recv().await
    }

    async fn app_sideload_task(&mut self) -> io::Result<()> {
        let mut params = self.params.clone();
        let command_field_count = 1;
        let current_dir = std::env::current_dir()?;
        let s = format!("{}{}", current_dir.display(), std::path::MAIN_SEPARATOR);
        params.insert(command_field_count, "-cwd".to_string());
        params.insert(command_field_count + 1, s);

        self.send(params.join(" ").as_bytes()).await;
        self.loop_recv().await
    }

    async fn flashd_task(&mut self) -> io::Result<()> {
        self.send(self.params.join(" ").as_bytes()).await;
        self.loop_recv().await
    }

    async fn check_server_task(&mut self) -> io::Result<()> {
        let params = self.params.clone();
        self.send(params.join(" ").as_bytes()).await;

        let recv = self.recv().await?;
        const CMD_U8_LEN: usize = 2;
        if recv.len() < CMD_U8_LEN {
            return Err(Error::new(ErrorKind::InvalidData, "recv failed"));
        }

        let cmd_slice = &recv[..CMD_U8_LEN];
        let cmd = u16::from_le_bytes([cmd_slice[0], cmd_slice[1]]);
        let version_slice = &recv[CMD_U8_LEN..];

        if cmd as u32 != HdcCommand::KernelCheckServer.as_u32() {
            return Err(Error::new(ErrorKind::InvalidData, "recv cmd error"));
        }
        let s_ver = String::from_utf8(version_slice.to_vec())
            .map_err(|err| Error::new(ErrorKind::InvalidData, format!("from_utf8 failed: {err}")))?;
        // Format expected by DevEco Studio: "client Ver: x.x.x.x, server Ver: x.x.x.x"
        println!("client {}, server {}", get_version(), s_ver);
        Ok(())
    }

    async fn version_task(&mut self) -> io::Result<()> {
        let params = self.params.clone();
        self.send(params.join(" ").as_bytes()).await;

        let recv = self.recv().await?;
        let s_ver = String::from_utf8(recv)
            .map_err(|err| Error::new(ErrorKind::InvalidData, format!("from_utf8 failed: {err}")))?;
        println!("{}", s_ver);
        Ok(())
    }
}

async fn read_server_message(rd: &mut tokio::net::tcp::OwnedReadHalf) -> io::Result<Vec<u8>> {
    let mut len_buf = [0u8; 4];
    rd.read_exact(&mut len_buf).await?;
    let len = u32::from_be_bytes(len_buf) as usize;
    let mut payload = vec![0u8; len];
    rd.read_exact(&mut payload).await?;
    Ok(payload)
}

/// RAII guard that puts the local terminal into raw-like mode for interactive shell
/// and restores the original mode on drop.
#[cfg(target_os = "windows")]
struct ConsoleModeGuard {
    original_mode: u32,
}

#[cfg(target_os = "windows")]
impl ConsoleModeGuard {
    fn new() -> Option<Self> {
        use windows_sys::Win32::System::Console::{
            GetConsoleMode, GetStdHandle, SetConsoleMode,
            ENABLE_ECHO_INPUT, ENABLE_LINE_INPUT, ENABLE_PROCESSED_INPUT,
            ENABLE_VIRTUAL_TERMINAL_INPUT,
            STD_INPUT_HANDLE,
        };
        unsafe {
            let handle = GetStdHandle(STD_INPUT_HANDLE);
            if handle == windows_sys::Win32::Foundation::INVALID_HANDLE_VALUE {
                return None;
            }
            let mut mode = 0u32;
            if GetConsoleMode(handle, &mut mode) == 0 {
                return None;
            }
            let original_mode = mode;
            let raw_mode = mode & !(ENABLE_ECHO_INPUT | ENABLE_LINE_INPUT | ENABLE_PROCESSED_INPUT);
            // Try enabling VT input (Windows 10+); if that fails, fall back to raw mode without it.
            let vt_mode = raw_mode | ENABLE_VIRTUAL_TERMINAL_INPUT;
            if SetConsoleMode(handle, vt_mode) == 0 {
                let _ = SetConsoleMode(handle, raw_mode);
            }
            Some(Self { original_mode })
        }
    }
}

#[cfg(target_os = "windows")]
impl Drop for ConsoleModeGuard {
    fn drop(&mut self) {
        use windows_sys::Win32::System::Console::{
            GetStdHandle, SetConsoleMode, STD_INPUT_HANDLE,
        };
        unsafe {
            let handle = GetStdHandle(STD_INPUT_HANDLE);
            if handle != windows_sys::Win32::Foundation::INVALID_HANDLE_VALUE {
                let _ = SetConsoleMode(handle, self.original_mode);
            }
        }
    }
}

#[cfg(unix)]
struct ConsoleModeGuard {
    original_termios: libc::termios,
}

#[cfg(unix)]
impl ConsoleModeGuard {
    fn new() -> Option<Self> {
        use libc::{tcgetattr, tcsetattr, ECHO, ICANON, ISIG, TCSANOW, VMIN, VTIME};
        unsafe {
            let mut termios = std::mem::MaybeUninit::<libc::termios>::uninit();
            if tcgetattr(0, termios.as_mut_ptr()) != 0 {
                return None;
            }
            let original_termios = termios.assume_init();
            let mut termios = original_termios;
            termios.c_lflag &= !(ECHO | ICANON | ISIG);
            termios.c_cc[VMIN] = 1;
            termios.c_cc[VTIME] = 0;
            let _ = tcsetattr(0, TCSANOW, &termios);
            Some(Self { original_termios })
        }
    }
}

#[cfg(unix)]
impl Drop for ConsoleModeGuard {
    fn drop(&mut self) {
        use libc::{tcsetattr, TCSANOW};
        unsafe {
            let _ = tcsetattr(0, TCSANOW, &self.original_termios);
        }
    }
}

/// Windows-specific raw console read using `ReadConsoleInputW`.
/// Unlike `ReadConsoleW` / `ReadFile`, this reads raw keyboard events directly
/// from the console input buffer, bypassing line-buffering and signal processing.
#[cfg(target_os = "windows")]
fn read_console_raw(buf: &mut [u8]) -> io::Result<usize> {
    use windows_sys::Win32::System::Console::{
        GetStdHandle, ReadConsoleInputW, KEY_EVENT, STD_INPUT_HANDLE,
        INPUT_RECORD, LEFT_CTRL_PRESSED, RIGHT_CTRL_PRESSED,
    };
    unsafe {
        let handle = GetStdHandle(STD_INPUT_HANDLE);
        if handle == windows_sys::Win32::Foundation::INVALID_HANDLE_VALUE {
            return Err(io::Error::new(io::ErrorKind::Other, "invalid stdin handle"));
        }

        let mut record: INPUT_RECORD = std::mem::zeroed();
        let mut read = 0u32;

        loop {
            let ok = ReadConsoleInputW(handle, &mut record, 1, &mut read);
            if ok == 0 {
                return Err(io::Error::last_os_error());
            }
            if read == 0 {
                return Ok(0);
            }

            // We only care about key-down events.
            if record.EventType as u32 != KEY_EVENT {
                continue;
            }
            let key_event = record.Event.KeyEvent;
            if key_event.bKeyDown == 0 {
                continue;
            }

            let ctrl = key_event.dwControlKeyState & (LEFT_CTRL_PRESSED | RIGHT_CTRL_PRESSED) != 0;
            let ch = key_event.uChar.UnicodeChar;

            // Virtual keys that have no UnicodeChar (arrow keys, etc.).
            if ch == 0 {
                let seq = match key_event.wVirtualKeyCode {
                    0x21 => Some(b"\x1b[5~".as_slice()),   // VK_PRIOR  (PageUp)
                    0x22 => Some(b"\x1b[6~".as_slice()),   // VK_NEXT   (PageDown)
                    0x23 => Some(b"\x1b[F".as_slice()),    // VK_END
                    0x24 => Some(b"\x1b[H".as_slice()),    // VK_HOME
                    0x25 => Some(b"\x1b[D".as_slice()),    // VK_LEFT
                    0x26 => Some(b"\x1b[A".as_slice()),    // VK_UP
                    0x27 => Some(b"\x1b[C".as_slice()),    // VK_RIGHT
                    0x28 => Some(b"\x1b[B".as_slice()),    // VK_DOWN
                    0x2D => Some(b"\x1b[2~".as_slice()),   // VK_INSERT
                    0x2E => Some(b"\x1b[3~".as_slice()),   // VK_DELETE
                    // Ctrl+A .. Ctrl+Z when UnicodeChar is empty.
                    0x41..=0x5A if ctrl => {
                        buf[0] = (key_event.wVirtualKeyCode - 0x40) as u8;
                        return Ok(1);
                    }
                    _ => None,
                };
                if let Some(seq) = seq {
                    let len = seq.len().min(buf.len());
                    buf[..len].copy_from_slice(&seq[..len]);
                    return Ok(len);
                }
                continue;
            }

            // ASCII range – map directly.
            if ch <= 0x7F {
                buf[0] = ch as u8;
                return Ok(1);
            }

            // Other Unicode – encode as UTF-8.
            let c = match char::from_u32(ch as u32) {
                Some(c) => c,
                None => continue,
            };
            let mut tmp = [0u8; 4];
            let bytes = c.encode_utf8(&mut tmp).as_bytes();
            let len = bytes.len().min(buf.len());
            buf[..len].copy_from_slice(&bytes[..len]);
            return Ok(len);
        }
    }
}

async fn interactive_shell_loop(
    mut rd: tokio::net::tcp::OwnedReadHalf,
    mut wr: tokio::net::tcp::OwnedWriteHalf,
) -> io::Result<()> {
    let mut stdout = tokio::io::stdout();

    // Put terminal into raw-like mode so that Ctrl+C, Ctrl+Z, Backspace, etc.
    // are sent as raw bytes to the remote shell instead of being handled locally.
    let _console_guard = ConsoleModeGuard::new();

    // Spawn stdin reader task
    let (stdin_tx, mut stdin_rx) = tokio::sync::mpsc::channel::<Vec<u8>>(64);

    #[cfg(target_os = "windows")]
    let stdin_handle = {
        let stdin_tx = stdin_tx.clone();
        tokio::spawn(async move {
            loop {
                let result = tokio::task::spawn_blocking(|| {
                    let mut buf = [0u8; 64];
                    match read_console_raw(&mut buf) {
                        Ok(0) => Ok(None),
                        Ok(n) => Ok(Some(buf[..n].to_vec())),
                        Err(e) => Err(e),
                    }
                }).await;
                match result {
                    Ok(Ok(Some(data))) => {
                        if stdin_tx.send(data).await.is_err() {
                            break;
                        }
                    }
                    _ => break,
                }
            }
        })
    };

    #[cfg(not(target_os = "windows"))]
    let stdin_handle = {
        let mut stdin = tokio::io::stdin();
        let mut stdin_buf = vec![0u8; 1024];
        tokio::spawn(async move {
            loop {
                match stdin.read(&mut stdin_buf).await {
                    Ok(0) => break,
                    Ok(n) => {
                        if stdin_tx.send(stdin_buf[..n].to_vec()).await.is_err() {
                            break;
                        }
                    }
                    Err(_) => break,
                }
            }
        })
    };

    // Main loop: bridge stdin->server and server->stdout.
    // Server direction is checked first (biased) so that when the daemon closes
    // the channel we break promptly instead of waiting forever on stdin.
    let result = loop {
        tokio::select! {
            biased;
            data = read_server_message(&mut rd) => {
                match data {
                    Ok(d) => {
                        if stdout.write_all(&d).await.is_err() {
                            break Ok(());
                        }
                        if stdout.flush().await.is_err() {
                            break Ok(());
                        }
                    }
                    Err(_) => {
                        // Server closed the connection. On Windows tokio::io::stdin()
                        // blocks in a background thread that abort() cannot interrupt,
                        // so we must force-exit to avoid hanging forever.
                        #[cfg(target_os = "windows")]
                        std::process::exit(0);
                        #[cfg(not(target_os = "windows"))]
                        break Ok(());
                    }
                }
            }
            Some(data) = stdin_rx.recv() => {
                let msg = [&(data.len() as u32).to_be_bytes()[..], &data].concat();
                if wr.write_all(&msg).await.is_err() {
                    break Ok(());
                }
            }
            else => break Ok(()),
        }
    };

    // Abort the stdin task so the process can exit promptly.
    stdin_handle.abort();
    let _ = stdin_handle.await;

    // _console_guard is dropped here, restoring the original terminal mode.
    result
}

pub async fn run_client_mode(parsed_cmd: ParsedCommand) -> io::Result<()> {
    match parsed_cmd.command {
        Some(HdcCommand::KernelServerStart) => {
            if parsed_cmd.parameters.contains(&"-r".to_string()) {
                server::server_kill().await;
            }
            server::server_fork(&parsed_cmd.server_addr, parsed_cmd.log_level, &parsed_cmd.forward_listen_ip).await;
            return Ok(());
        }
        Some(HdcCommand::KernelServerKill) => {
            server::server_kill().await;
            if parsed_cmd.parameters.contains(&"-r".to_string()) {
                server::server_fork(&parsed_cmd.server_addr, parsed_cmd.log_level, &parsed_cmd.forward_listen_ip).await;
            }
            return Ok(());
        }
        Some(HdcCommand::KernelHelp) => {
            println!("{}", crate::parser::usage());
            return Ok(());
        }
        Some(HdcCommand::ClientKeyGenerate) => {
            match crate::auth::load_or_generate_keys() {
                Ok(_) => println!("RSA key generated successfully"),
                Err(e) => eprintln!("Failed to generate RSA key: {e}"),
            }
            return Ok(());
        }
        _ => {}
    };

    if parsed_cmd.launch_server {
        // Check if server is running; if not, start it
        if TcpStream::connect(&parsed_cmd.server_addr).await.is_err() {
            server::server_fork(&parsed_cmd.server_addr, parsed_cmd.log_level, &parsed_cmd.forward_listen_ip).await;
            // Give server time to start
            tokio::time::sleep(tokio::time::Duration::from_millis(500)).await;
        }
    }

    let mut client = Client::new(&parsed_cmd).await?;
    if let Err(e) = client.handshake().await {
        error!("handshake with server failed: {e:?}");
        return Err(e);
    }
    client.execute_command().await
}

#[cfg(test)]
mod uninstall_tests {
    use super::*;
    use tokio::net::TcpListener;

    fn frame(payload: &[u8]) -> Vec<u8> {
        [&(payload.len() as u32).to_be_bytes()[..], payload].concat()
    }

    async fn uninstall_reply(reply: Vec<u8>) -> (io::Result<()>, String) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let stream = TcpStream::connect(listener.local_addr().unwrap()).await.unwrap();
        let (mut peer, _) = listener.accept().await.unwrap();
        let writer = tokio::spawn(async move {
            let size = peer.read_u32().await.unwrap() as usize;
            let mut command = vec![0; size];
            peer.read_exact(&mut command).await.unwrap();
            assert_eq!(command, b"uninstall com.example.test");
            peer.write_all(&reply).await.unwrap();
            peer.shutdown().await.unwrap();
        });
        let (rd, wr) = stream.into_split();
        let mut client = Client {
            command: HdcCommand::AppUninstall,
            params: vec!["uninstall".into(), "com.example.test".into()],
            connect_key: String::new(), rd: Some(rd), wr: Some(wr), output: String::new(),
        };
        let result = client.execute_command().await;
        writer.await.unwrap();
        (result, client.take_output())
    }

    #[tokio::test]
    async fn preserves_uninstall_receipt_before_clean_eof() {
        let mut reply = frame(b"uninstall bundle ");
        reply.extend(frame(b"successfully.\n"));
        let (result, output) = uninstall_reply(reply).await;
        result.unwrap();
        assert_eq!(output, "uninstall bundle successfully.\n");
    }

    #[tokio::test]
    async fn retains_device_rejection_for_the_caller() {
        let (result, output) = uninstall_reply(frame(b"[Fail]permission denied\n")).await;
        result.unwrap();
        assert_eq!(output, "[Fail]permission denied\n");
    }

    #[tokio::test]
    async fn empty_eof_does_not_fabricate_a_success_receipt() {
        let (result, output) = uninstall_reply(vec![]).await;
        result.unwrap();
        assert!(output.is_empty());
    }

    #[tokio::test]
    async fn rejects_truncated_response_frames() {
        for reply in [vec![0, 0], 10_u32.to_be_bytes().to_vec(),
            [&10_u32.to_be_bytes()[..], b"abc"].concat()] {
            let (result, _) = uninstall_reply(reply).await;
            assert_eq!(result.unwrap_err().kind(), ErrorKind::UnexpectedEof);
        }
    }
}
