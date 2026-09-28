//! HDC protocol constants and command definitions.

use std::convert::TryFrom;

pub const PACKET_FLAG: &[u8] = b"HW";
pub const USB_PACKET_FLAG: &[u8] = b"UB";
pub const USB_OPTION_HEADER: u8 = 1;
pub const USB_OPTION_RESET: u8 = 2;
pub const VER_PROTOCOL: u16 = 1;
pub const ENABLE_IO_CHECK: bool = false;
pub const PAYLOAD_VCODE: u8 = 0x09;
pub const HDC_BUF_MAX_SIZE: usize = 0x7fff_ffff;
pub const HANDSHAKE_MESSAGE: &str = "OHOS HDC";
pub const BANNER_SIZE: usize = 12;
pub const KEY_MAX_SIZE: usize = 32;
pub const FILE_PACKAGE_HEAD: usize = 64;
pub const FILE_PACKAGE_PAYLOAD_SIZE: usize = 49152;
pub const KERNEL_FILE_NODE_SIZE: u16 = 1024 * 4;
pub const MAX_PACKET_SIZE_HISPEED: i32 = 512;
pub const MAX_SIZE_IOBUF: usize = 511 * 1024;
pub const MAX_USBFFS_BULK: usize = 512 * 1024;
pub const MAX_SIZE_IOBUF_STABLE: usize = 60 * 1024;
pub const MAX_USBFFS_BULK_STABLE: usize = 61 * 1024;
pub const MAX_DIED_SESSION_NUM: usize = 10;

pub const FEATURE_FLAG_MAX_SIZE: usize = 8;
pub const HEARTBEAT_INTERVAL: u16 = 5000;
pub const SSL_HANDSHAKE_FINISHED_WAIT_TIME: u16 = 300;
pub const BUF_SIZE_SSL_HEAD: u16 = 22;
pub const BUF_SIZE_PSK: u16 = 32;
pub const BUF_SIZE_PSK_ENCRYPTED: u16 = 512;

pub const ENV_SERVER_HEARTBEAT: &str = "OHOS_HDC_HEARTBEAT";
pub const ENV_ENCRYPT_CHANNEL: &str = "OHOS_HDC_ENCRYPT_CHANNEL";
pub const ENV_SERVER_LOG_LIMIT: &str = "OHOS_HDC_LOG_LIMIT";

pub const HUGE_BUF_TAG: char = 'H';
pub const BANNER_FEATURE_TAG_OFFSET: usize = 11;
pub const WAIT_DEVICE_TAG: char = 'W';
pub const WAIT_TAG_OFFSET: usize = 11;

pub const SHELL_PROG: &str = "sh";
pub const WIN_CMD_PROG: &str = "cmd.exe";

pub const FEATURE_ENCRYPT_TCP: &str = "encrypt_tcp";
pub const FEATURE_HEARTBEAT: &str = "heartbeat";

// Authentication type values (matches official HdcSessionBase::AuthType)
pub const AUTH_TYPE_NONE: u8 = 0;
pub const AUTH_TYPE_TOKEN: u8 = 1;
pub const AUTH_TYPE_SIGNATURE: u8 = 2;
pub const AUTH_TYPE_PUBLICKEY: u8 = 3;
pub const AUTH_TYPE_OK: u8 = 4;
pub const AUTH_TYPE_FAIL: u8 = 5;
pub const AUTH_TYPE_SSL_TLS_PSK: u8 = 6;
pub const SHELL_TEMP: &str = "/data/local/tmp/hdc-pty";

pub const DAEMON_PORT: u16 = 0;
pub const SERVER_DEFAULT_PORT: u16 = 8710;
pub const MAX_PORT_NUM: u32 = 65535;
pub const LOCAL_HOST: &str = "127.0.0.1";

pub const USB_FFS_BASE: &str = "/dev/usb-ffs/";
pub const USB_QUEUE_LEN: usize = 64;

pub const INSTALL_TMP_DIR: &str = "/data/local/tmp/";
pub const INSTALL_TAR_MAX_CNT: usize = 512;

pub const RSA_BIT_NUM: usize = 3072;
pub const RSA_PUBKEY_PATH: &str = "/data/service/el1/public/hdc";
pub const RSA_PUBKEY_NAME: &str = "hdc_keys";
pub const RSA_PRIKEY_PATH: &str = ".harmony";
pub const RSA_PRIKEY_NAME: &str = "hdckey";
pub const HDC_HOST_DAEMON_BUF_SEPARATOR: char = '\x0C';
pub const HDC_HANDSHAKE_TOKEN_LEN: usize = 32;

pub const DAEOMN_AUTH_SUCCESS: &str = "SUCCESS";
pub const DAEOMN_UNAUTHORIZED: &str = "DAEMON_UNAUTH";

// Version format aligned with official C++:
// |----------------------------------------------------------------|
// | 31-28 | 27-24 | 23-20 | 19-16 | 15-12 | 11-08 |     07-00      |
// |----------------------------------------------------------------|
// | major |reserve| minor |reserve|version|  fix  |   reserve      |
// |----------------------------------------------------------------|
// 0x3020_0500 is Ver: 3.2.0f
const HDC_VERSION_NUMBER: u32 = 0x3020_0500;
pub const AUTH_BASE_VERSION: &str = "Ver: 3.2.0b";

pub fn get_version() -> String {
    let major = (HDC_VERSION_NUMBER >> 28) & 0xff;
    let minor = (HDC_VERSION_NUMBER << 4 >> 24) & 0xff;
    let version = (HDC_VERSION_NUMBER << 12 >> 24) & 0xff;
    let fix = std::char::from_u32((HDC_VERSION_NUMBER << 20 >> 28) + 0x61).unwrap_or('?');
    format!("Ver: {major}.{minor}.{version}{fix}")
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum CompressType {
    #[default]
    None = 0,
    Lz4 = 1,
    Lz77 = 2,
    Lzma = 3,
    Brotli = 4,
}

impl TryFrom<u8> for CompressType {
    type Error = ();
    fn try_from(cmd: u8) -> Result<Self, ()> {
        match cmd {
            0 => Ok(Self::None),
            1 => Ok(Self::Lz4),
            2 => Ok(Self::Lz77),
            3 => Ok(Self::Lzma),
            4 => Ok(Self::Brotli),
            _ => Err(()),
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub enum ConnectType {
    Usb(String),
    #[default]
    Tcp,
    Uart,
    Bt,
    Bridge,
    HostUsb(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NodeType {
    Server,
    Daemon,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConnStatus {
    Ready = 0,
    Connected = 1,
    Offline = 2,
    Unauthorized = 3,
}

#[derive(Debug, Clone)]
pub struct TaskMessage {
    pub channel_id: u32,
    pub command: HdcCommand,
    pub payload: Vec<u8>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HdcCommand {
    KernelHelp = 0,
    KernelHandshake = 1,
    KernelChannelClose = 2,
    KernelTargetDiscover = 4,
    KernelTargetList = 5,
    KernelTargetAny = 6,
    KernelTargetConnect = 7,
    KernelTargetDisconnect = 8,
    KernelEcho = 9,
    KernelEchoRaw = 10,
    KernelEnableKeepalive = 11,
    KernelWakeupSlavetask = 12,
    KernelCheckServer = 13,
    KernelCheckDevice = 14,
    KernelWaitFor = 15,

    // Values 16-20 mirror the official enum (CMD_SERVER_KILL / CMD_SERVICE_START /
    // CMD_KERNEL_TARGET_RECONNECT / CMD_SSL_HANDSHAKE). They are only exchanged
    // between our own client and server as in-process dispatch tags; the wire
    // encoding between client and server is the plain-text command line.
    KernelServerKill = 16,
    KernelServerStart = 17,
    KernelTargetReconnect = 18,
    ClientVersion = 19,
    SslHandshake = 20,
    ClientKeyGenerate = 21,

    UnityCommandHead = 1000,
    UnityExecute = 1001,
    UnityRemount = 1002,
    UnityReboot = 1003,
    UnityRunmode = 1004,
    UnityHilog = 1005,
    UnityTerminate = 1006,
    UnityRootrun = 1007,
    JdwpList = 1008,
    JdwpTrack = 1009,
    UnityCommandTail = 1010,
    UnityBugreportInit = 1011,
    UnityBugreportData = 1012,
    UnityExecuteEx = 1200,

    ShellInit = 2000,
    ShellData = 2001,

    ForwardInit = 2500,
    ForwardCheck = 2501,
    ForwardCheckResult = 2502,
    ForwardActiveSlave = 2503,
    ForwardActiveMaster = 2504,
    ForwardData = 2505,
    ForwardFreeContext = 2506,
    ForwardList = 2507,
    ForwardRemove = 2508,
    ForwardSuccess = 2509,
    ForwardRportInit = 2510,
    ForwardRportList = 2511,
    ForwardRportRemove = 2512,

    FileInit = 3000,
    FileCheck = 3001,
    FileBegin = 3002,
    FileData = 3003,
    FileFinish = 3004,
    AppSideload = 3005,
    FileMode = 3006,
    DirMode = 3007,
    FileRecvInit = 3008,

    AppInit = 3500,
    AppCheck = 3501,
    AppBegin = 3502,
    AppData = 3503,
    AppFinish = 3504,
    AppUninstall = 3505,

    FlashdUpdateInit = 4000,
    FlashdFlashInit = 4001,
    FlashdCheck = 4002,
    FlashdBegin = 4003,
    FlashdData = 4004,
    FlashdFinish = 4005,
    FlashdErase = 4006,
    FlashdFormat = 4007,
    FlashdProgress = 4008,

    HeartbeatMsg = 5000,
    SpawnSub = 6000,
}

impl TryFrom<u32> for HdcCommand {
    type Error = ();
    fn try_from(cmd: u32) -> Result<Self, ()> {
        match cmd {
            0 => Ok(Self::KernelHelp),
            1 => Ok(Self::KernelHandshake),
            2 => Ok(Self::KernelChannelClose),
            4 => Ok(Self::KernelTargetDiscover),
            5 => Ok(Self::KernelTargetList),
            6 => Ok(Self::KernelTargetAny),
            7 => Ok(Self::KernelTargetConnect),
            8 => Ok(Self::KernelTargetDisconnect),
            9 => Ok(Self::KernelEcho),
            10 => Ok(Self::KernelEchoRaw),
            11 => Ok(Self::KernelEnableKeepalive),
            12 => Ok(Self::KernelWakeupSlavetask),
            13 => Ok(Self::KernelCheckServer),
            14 => Ok(Self::KernelCheckDevice),
            15 => Ok(Self::KernelWaitFor),
            16 => Ok(Self::KernelServerKill),
            17 => Ok(Self::KernelServerStart),
            18 => Ok(Self::KernelTargetReconnect),
            19 => Ok(Self::ClientVersion),
            20 => Ok(Self::SslHandshake),
            21 => Ok(Self::ClientKeyGenerate),
            1000 => Ok(Self::UnityCommandHead),
            1001 => Ok(Self::UnityExecute),
            1002 => Ok(Self::UnityRemount),
            1003 => Ok(Self::UnityReboot),
            1004 => Ok(Self::UnityRunmode),
            1005 => Ok(Self::UnityHilog),
            1006 => Ok(Self::UnityTerminate),
            1007 => Ok(Self::UnityRootrun),
            1008 => Ok(Self::JdwpList),
            1009 => Ok(Self::JdwpTrack),
            1010 => Ok(Self::UnityCommandTail),
            1011 => Ok(Self::UnityBugreportInit),
            1012 => Ok(Self::UnityBugreportData),
            1200 => Ok(Self::UnityExecuteEx),
            2000 => Ok(Self::ShellInit),
            2001 => Ok(Self::ShellData),
            2500 => Ok(Self::ForwardInit),
            2501 => Ok(Self::ForwardCheck),
            2502 => Ok(Self::ForwardCheckResult),
            2503 => Ok(Self::ForwardActiveSlave),
            2504 => Ok(Self::ForwardActiveMaster),
            2505 => Ok(Self::ForwardData),
            2506 => Ok(Self::ForwardFreeContext),
            2507 => Ok(Self::ForwardList),
            2508 => Ok(Self::ForwardRemove),
            2509 => Ok(Self::ForwardSuccess),
            2510 => Ok(Self::ForwardRportInit),
            2511 => Ok(Self::ForwardRportList),
            2512 => Ok(Self::ForwardRportRemove),
            3000 => Ok(Self::FileInit),
            3001 => Ok(Self::FileCheck),
            3002 => Ok(Self::FileBegin),
            3003 => Ok(Self::FileData),
            3004 => Ok(Self::FileFinish),
            3005 => Ok(Self::AppSideload),
            3006 => Ok(Self::FileMode),
            3007 => Ok(Self::DirMode),
            3008 => Ok(Self::FileRecvInit),
            3500 => Ok(Self::AppInit),
            3501 => Ok(Self::AppCheck),
            3502 => Ok(Self::AppBegin),
            3503 => Ok(Self::AppData),
            3504 => Ok(Self::AppFinish),
            3505 => Ok(Self::AppUninstall),
            4000 => Ok(Self::FlashdUpdateInit),
            4001 => Ok(Self::FlashdFlashInit),
            4002 => Ok(Self::FlashdCheck),
            4003 => Ok(Self::FlashdBegin),
            4004 => Ok(Self::FlashdData),
            4005 => Ok(Self::FlashdFinish),
            4006 => Ok(Self::FlashdErase),
            4007 => Ok(Self::FlashdFormat),
            4008 => Ok(Self::FlashdProgress),
            5000 => Ok(Self::HeartbeatMsg),
            6000 => Ok(Self::SpawnSub),
            _ => Err(()),
        }
    }
}

impl HdcCommand {
    pub fn as_u32(&self) -> u32 {
        *self as u32
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AuthType {
    None = 0,
    Token = 1,
    Signature = 2,
    Publickey = 3,
    Ok = 4,
    Fail = 5,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AppModeType {
    Install = 1,
    UnInstall = 2,
}

impl TryFrom<u8> for AppModeType {
    type Error = ();
    fn try_from(cmd: u8) -> Result<Self, ()> {
        match cmd {
            1 => Ok(Self::Install),
            2 => Ok(Self::UnInstall),
            _ => Err(()),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MessageLevel {
    Fail = 0,
    Info = 1,
    Ok = 2,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConnectValidationStatus {
    ValidationClose = 0,
    ValidationHost = 1,
    ValidationDaemon = 2,
    ValidationHostAndDaemon = 3,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ShellExecuteTag {
    TagShellCmd = 0x00000000,
    TagShellBundle = 0x00000001,
    TagShellDefault = 0xFFFFFFFF,
}
