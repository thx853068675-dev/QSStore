//! Command-line parser for the HDC host tool.

use hdc_protocol::config::{get_version, HdcCommand, SERVER_DEFAULT_PORT, LOCAL_HOST};
use std::collections::HashMap;
use std::io::{self, Error, ErrorKind};
use std::net::IpAddr;
use std::str::FromStr;
use std::sync::LazyLock;

#[derive(Debug, Clone, Default)]
pub struct ParsedCommand {
    pub run_in_server: bool,
    pub launch_server: bool,
    pub spawned_server: bool,
    pub connect_key: String,
    pub log_level: usize,
    pub server_addr: String,
    pub forward_listen_ip: String,
    pub command: Option<HdcCommand>,
    pub parameters: Vec<String>,
}

static CMD_MAP: LazyLock<HashMap<&'static str, HdcCommand>> = LazyLock::new(|| {
    let mut map = HashMap::new();
    map.insert("version", HdcCommand::ClientVersion);
    map.insert("help", HdcCommand::KernelHelp);
    map.insert("discover", HdcCommand::KernelTargetDiscover);
    map.insert("start", HdcCommand::KernelServerStart);
    map.insert("kill", HdcCommand::KernelServerKill);
    map.insert("keygen", HdcCommand::ClientKeyGenerate);
    map.insert("list targets", HdcCommand::KernelTargetList);
    map.insert("checkserver", HdcCommand::KernelCheckServer);
    map.insert("checkdevice", HdcCommand::KernelCheckDevice);
    map.insert("wait", HdcCommand::KernelWaitFor);
    map.insert("tconn", HdcCommand::KernelTargetConnect);
    map.insert("any", HdcCommand::KernelTargetAny);
    map.insert("shell", HdcCommand::UnityExecute);
    map.insert("target boot", HdcCommand::UnityReboot);
    map.insert("target mount", HdcCommand::UnityRemount);
    map.insert("smode", HdcCommand::UnityRootrun);
    map.insert("tmode", HdcCommand::UnityRunmode);
    map.insert("bugreport", HdcCommand::UnityBugreportInit);
    map.insert("hilog", HdcCommand::UnityHilog);
    map.insert("file send", HdcCommand::FileInit);
    map.insert("file recv", HdcCommand::FileRecvInit);
    map.insert("fport", HdcCommand::ForwardInit);
    map.insert("rport", HdcCommand::ForwardRportInit);
    map.insert("rport ls", HdcCommand::ForwardRportList);
    map.insert("fport ls", HdcCommand::ForwardList);
    map.insert("fport rm", HdcCommand::ForwardRemove);
    map.insert("rport rm", HdcCommand::ForwardRportRemove);
    map.insert("install", HdcCommand::AppInit);
    map.insert("uninstall", HdcCommand::AppUninstall);
    map.insert("sideload", HdcCommand::AppSideload);
    map.insert("jpid", HdcCommand::JdwpList);
    map.insert("track-jpid", HdcCommand::JdwpTrack);
    map.insert("alive", HdcCommand::KernelEnableKeepalive);
    map.insert("update", HdcCommand::FlashdUpdateInit);
    map.insert("flash", HdcCommand::FlashdFlashInit);
    map.insert("erase", HdcCommand::FlashdErase);
    map.insert("format", HdcCommand::FlashdFormat);
    map.insert("reconnect", HdcCommand::KernelTargetReconnect);
    map.insert("spawn-sub", HdcCommand::SpawnSub);
    map.insert("killall-sub", HdcCommand::SpawnSub);
    map
});

const MAX_CMD_LEN: usize = 3;

pub fn usage() -> String {
    r#"HDC (HarmonyOS Device Connector) Rust Implementation

Usage: hdc [options] [command]

Global Options:
  -h              Show this help message
  -v              Show version
  -l <level>      Set log level (0-6)
  -m              Run in server mode
  -p              Do not launch server automatically
  -t <key>        Target connect key
  -s <addr>       Server address (ip:port)
  -e <ip>         IP address for host to listen during TCP port forwarding
  -b              Server spawned by client (no stdout)

Commands:
  list targets              List connected devices
  tconn <ip:port>           Connect to device via TCP
  shell [cmd]               Execute shell command or enter interactive shell
  shell - [cmd]             Execute shell with bundle options
  file send <local> <remote> Send file to device
  file recv <remote> <local> Receive file from device
  install [options] <path...>  Install application package(s) (.hap/.hsp/.app)
                              options are passed to 'bm install' (e.g. -r replace,
                              -g grant permissions, -s shared bundle)
  uninstall <package>       Uninstall application
  fport [ls|rm]             Forward port management
  rport [ls|rm]             Reverse port management
  hilog                     Show device logs
  bugreport [path]          Generate bug report
  target boot [mode]        Reboot device
  target mount              Remount filesystem
  smode                     Switch root mode
  tmode                     Switch target mode
  jpid                      List JDWP processes
  track-jpid                Track JDWP processes
  update <package>          Update system by package (.zip/.img/...)
  flash [-f] <partition> <image>  Flash partition by image
  erase [-f] <partition>    Erase partition
  format [-f] <partition>   Format partition
  reconnect <key>           Reconnect USB device
  start [-r]                Start server (with -r to restart)
  kill [-r]                 Kill server (with -r to restart)
  checkserver               Check server version
  wait                      Wait for device connection
"#
    .to_string()
}

fn verbose_usage() -> String {
    usage() + "\nVerbose mode enabled.\n"
}

#[derive(Debug, Clone, Default)]
pub struct Parsed {
    pub options: Vec<String>,
    pub command: Option<HdcCommand>,
    pub parameters: Vec<String>,
}

pub fn split_opt_and_cmd(input: Vec<String>) -> Parsed {
    let mut cmd_opt: Option<HdcCommand> = None;
    let mut cmd_index = input.len();

    for st in 0..input.len() {
        for len in 1..=MAX_CMD_LEN {
            if st + len > input.len() {
                break;
            }
            let cmd = input[st..st + len].join(" ");
            if let Some(command) = CMD_MAP.get(cmd.as_str()) {
                // Special handling for forward commands
                if let Some(existing) = cmd_opt {
                    if (existing == HdcCommand::ForwardInit || existing == HdcCommand::ForwardRportInit)
                        && (*command != HdcCommand::ForwardRemove
                            && *command != HdcCommand::ForwardList
                            && *command != HdcCommand::ForwardRportList
                            && *command != HdcCommand::ForwardRportRemove)
                    {
                        break;
                    }
                }
                cmd_index = st;
                cmd_opt = Some(*command);
                if *command == HdcCommand::ForwardInit || *command == HdcCommand::ForwardRportInit {
                    continue;
                } else {
                    break;
                }
            }
        }
        if let Some(existing) = cmd_opt {
            if existing != HdcCommand::ForwardInit && existing != HdcCommand::ForwardRportInit {
                break;
            }
        }
    }

    Parsed {
        options: input[..cmd_index].to_vec(),
        command: cmd_opt,
        parameters: input[cmd_index..].to_vec(),
    }
}

fn check_port(port_str: &str) -> io::Result<u16> {
    // Official ValidatePort: 1-5 digit characters, value in 1..=65535.
    if port_str.is_empty()
        || port_str.len() > 5
        || !port_str.bytes().all(|b| b.is_ascii_digit())
    {
        return Err(Error::new(ErrorKind::InvalidInput, "The port must be digit str"));
    }
    match port_str.parse::<u16>() {
        Ok(port) if port > 0 => Ok(port),
        _ => Err(Error::new(ErrorKind::InvalidInput, "Port range incorrect")),
    }
}

/// Normalize a listen address into a form `std::net::SocketAddr` can parse:
/// - IPv4-mapped IPv6 without brackets ("::ffff:127.0.0.1:8710", the form shown
///   by netstat/ss) becomes plain IPv4 ("127.0.0.1:8710");
/// - unbracketed IPv6 with a port ("::1:8710") becomes bracketed ("[::1]:8710").
pub(crate) fn normalize_listen_addr(s: &str) -> String {
    if s.parse::<std::net::SocketAddr>().is_ok() {
        return s.to_string();
    }
    if let Some(rest) = s.to_ascii_lowercase().strip_prefix("::ffff:") {
        if let Ok(v4) = rest.parse::<std::net::SocketAddrV4>() {
            return v4.to_string();
        }
    }
    if let Some((host, port)) = s.rsplit_once(':') {
        if port.parse::<u16>().is_ok()
            && host
                .parse::<std::net::IpAddr>()
                .is_ok_and(|ip| ip.is_ipv6())
        {
            return format!("[{host}]:{port}");
        }
    }
    s.to_string()
}

fn parse_server_listen_string(arg: &str) -> io::Result<String> {
    let addr = normalize_listen_addr(arg);
    let segments: Vec<&str> = addr.split(':').collect();
    let port_str = segments.last().copied().unwrap_or("");
    let port = check_port(port_str)?;

    if segments.len() == 1 {
        return Ok(format!("{}:{}", LOCAL_HOST, port));
    }

    let port_len = port_str.len();
    let ip_str = addr[..addr.len() - port_len - 1]
        .trim_start_matches('[')
        .trim_end_matches(']');
    match IpAddr::from_str(ip_str) {
        Ok(ip) if ip.is_ipv4() || ip.is_ipv6() => Ok(addr),
        _ => Err(Error::new(ErrorKind::InvalidInput, "-s content ip incorrect")),
    }
}

pub fn parse_command(args: impl Iterator<Item = String>) -> io::Result<ParsedCommand> {
    let input: Vec<String> = args.skip(1).collect();
    let parsed = split_opt_and_cmd(input);
    let mut parsed_cmd = extract_global_params(parsed.options)?;
    parsed_cmd.command = parsed.command;
    parsed_cmd.parameters = parsed.parameters;

    // Post-process: "shell -" maps to UnityExecuteEx (supports bundle options)
    if parsed_cmd.command == Some(HdcCommand::UnityExecute) {
        if parsed_cmd.parameters.len() >= 2 && parsed_cmd.parameters[0] == "-" {
            parsed_cmd.command = Some(HdcCommand::UnityExecuteEx);
        }
    }

    Ok(parsed_cmd)
}

fn extract_global_params(opts: Vec<String>) -> io::Result<ParsedCommand> {
    let mut parsed = ParsedCommand {
        launch_server: true,
        log_level: 3,
        server_addr: format!("{}:{}", LOCAL_HOST, SERVER_DEFAULT_PORT),
        forward_listen_ip: LOCAL_HOST.to_string(),
        ..Default::default()
    };

    let len = opts.len();
    let mut i = 0;
    while i < len {
        let opt = opts[i].as_str();
        let arg = if opt.len() > 2 {
            &opt[2..]
        } else if i < len - 1 {
            opts[i + 1].as_str()
        } else {
            ""
        };

        if opt.starts_with("-h") {
            if arg == "verbose" {
                return Err(Error::new(ErrorKind::Other, verbose_usage()));
            } else {
                return Err(Error::new(ErrorKind::Other, usage()));
            }
        } else if opt.starts_with("-v") {
            return Err(Error::new(ErrorKind::Other, get_version()));
        } else if opt.starts_with("-l") {
            if let Ok(level) = arg.parse::<usize>() {
                if level < 7 {
                    parsed.log_level = level;
                } else {
                    return Err(Error::new(
                        ErrorKind::InvalidInput,
                        format!("-l content loglevel incorrect\n\n{}", usage()),
                    ));
                }
            } else {
                return Err(Error::new(
                    ErrorKind::InvalidInput,
                    format!("-l content loglevel incorrect\n\n{}", usage()),
                ));
            }
        } else if opt.starts_with("-m") {
            parsed.run_in_server = true;
        } else if opt.starts_with("-p") {
            parsed.launch_server = false;
        } else if opt.starts_with("-t") {
            parsed.connect_key = arg.to_string();
            if parsed.connect_key.len() > 32 {
                return Err(Error::new(
                    ErrorKind::InvalidInput,
                    format!("Size of param '-t' {} is too long", arg.len()),
                ));
            }
        } else if opt.starts_with("-s") {
            parsed.server_addr = parse_server_listen_string(arg)?;
        } else if opt.starts_with("-e") {
            match IpAddr::from_str(arg) {
                Ok(ip) if ip.is_ipv4() || ip.is_ipv6() => {
                    parsed.forward_listen_ip = arg.to_string();
                }
                _ => {
                    return Err(Error::new(
                        ErrorKind::InvalidInput,
                        "-e content IP incorrect",
                    ));
                }
            }
        } else if opt.starts_with("-b") {
            parsed.spawned_server = true;
        }
        i += 1;
    }

    Ok(parsed)
}

pub fn auto_connect_key(key: &str, cmd: HdcCommand) -> String {
    match cmd {
        HdcCommand::ClientVersion
        | HdcCommand::KernelHelp
        | HdcCommand::KernelTargetList
        | HdcCommand::KernelCheckServer
        | HdcCommand::KernelTargetConnect
        | HdcCommand::KernelServerKill => String::new(),
        _ => {
            if key.is_empty() {
                "any".to_string()
            } else {
                key.to_string()
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize_listen_addr_keeps_valid_forms() {
        assert_eq!(normalize_listen_addr("127.0.0.1:8710"), "127.0.0.1:8710");
        assert_eq!(normalize_listen_addr("0.0.0.0:8710"), "0.0.0.0:8710");
        assert_eq!(normalize_listen_addr("[::1]:8710"), "[::1]:8710");
    }

    #[test]
    fn normalize_listen_addr_mapped_ipv6_becomes_ipv4() {
        assert_eq!(normalize_listen_addr("::ffff:127.0.0.1:8710"), "127.0.0.1:8710");
        assert_eq!(normalize_listen_addr("::FFFF:127.0.0.1:8710"), "127.0.0.1:8710");
        assert_eq!(normalize_listen_addr("::ffff:0.0.0.0:8710"), "0.0.0.0:8710");
    }

    #[test]
    fn normalize_listen_addr_unbracketed_ipv6_gets_brackets() {
        assert_eq!(normalize_listen_addr("::1:8710"), "[::1]:8710");
    }

    #[test]
    fn parse_server_listen_string_accepts_mapped_ipv6() {
        assert_eq!(
            parse_server_listen_string("::ffff:127.0.0.1:8710").unwrap(),
            "127.0.0.1:8710"
        );
    }

    #[test]
    fn parse_server_listen_string_accepts_bracketed_ipv6() {
        assert_eq!(
            parse_server_listen_string("[::1]:8710").unwrap(),
            "[::1]:8710"
        );
    }

    #[test]
    fn parse_server_listen_string_rejects_bad_input() {
        assert!(parse_server_listen_string("garbage:8710").is_err());
        assert!(parse_server_listen_string("127.0.0.1:notaport").is_err());
    }
}
