//! Pure-Rust serialization/deserialization for HDC protocol structures.
//!
//! Replaces the C FFI based serialization with a Rust-native implementation.
//!
//! Fixed-size structures (PayloadHead, UsbHead, UartHead) are serialized manually
//! field-by-field in big-endian byte order.
//!
//! TLV structures (SessionHandShake, TransferConfig, FileMode, TransferPayload,
//! PayloadProtect) use a protobuf-like encoding with varint tags and lengths.

use crate::config::*;
use std::io::{self, Error, ErrorKind};

// ============================================================================
// Varint helpers (protobuf-style base-128 varints)
// ============================================================================

fn write_varint_u32(value: u32, buf: &mut Vec<u8>) {
    let mut v = value;
    loop {
        let mut b = (v & 0x7f) as u8;
        v >>= 7;
        if v != 0 {
            b |= 0x80;
        }
        buf.push(b);
        if v == 0 {
            break;
        }
    }
}

fn write_varint_u64(value: u64, buf: &mut Vec<u8>) {
    let mut v = value;
    loop {
        let mut b = (v & 0x7f) as u8;
        v >>= 7;
        if v != 0 {
            b |= 0x80;
        }
        buf.push(b);
        if v == 0 {
            break;
        }
    }
}

fn read_varint_u32(bytes: &[u8], offset: &mut usize) -> io::Result<u32> {
    let mut value = 0u32;
    let mut shift = 0;
    loop {
        if *offset >= bytes.len() {
            return Err(Error::new(ErrorKind::InvalidData, "truncated varint"));
        }
        let b = bytes[*offset];
        *offset += 1;
        value |= ((b & 0x7f) as u32) << shift;
        if b & 0x80 == 0 {
            return Ok(value);
        }
        shift += 7;
        if shift >= 32 {
            return Err(Error::new(ErrorKind::InvalidData, "varint overflow"));
        }
    }
}

fn read_varint_u64(bytes: &[u8], offset: &mut usize) -> io::Result<u64> {
    let mut value = 0u64;
    let mut shift = 0;
    loop {
        if *offset >= bytes.len() {
            return Err(Error::new(ErrorKind::InvalidData, "truncated varint"));
        }
        let b = bytes[*offset];
        *offset += 1;
        value |= ((b & 0x7f) as u64) << shift;
        if b & 0x80 == 0 {
            return Ok(value);
        }
        shift += 7;
        if shift >= 64 {
            return Err(Error::new(ErrorKind::InvalidData, "varint overflow"));
        }
    }
}

// ============================================================================
// Protobuf-like TLV helpers
// ============================================================================

const WIRE_VARINT: u32 = 0;
const WIRE_FIXED64: u32 = 1;
const WIRE_LENGTH_DELIMITED: u32 = 2;
const WIRE_FIXED32: u32 = 5;

fn make_tag(field_number: u32, wire_type: u32) -> u32 {
    (field_number << 3) | wire_type
}

fn read_tag_wire_type(tag_key: u32) -> (u32, u32) {
    (tag_key >> 3, tag_key & 0x07)
}

fn write_tag(field_number: u32, wire_type: u32, buf: &mut Vec<u8>) {
    write_varint_u32(make_tag(field_number, wire_type), buf);
}

fn write_u32_field(field_number: u32, value: u32, buf: &mut Vec<u8>) {
    if value == 0 {
        return; // skip default zero values for optional fields
    }
    write_tag(field_number, WIRE_VARINT, buf);
    write_varint_u32(value, buf);
}

fn write_u64_field(field_number: u32, value: u64, buf: &mut Vec<u8>) {
    if value == 0 {
        return;
    }
    write_tag(field_number, WIRE_VARINT, buf);
    write_varint_u64(value, buf);
}

fn write_bool_field(field_number: u32, value: bool, buf: &mut Vec<u8>) {
    if !value {
        return;
    }
    write_tag(field_number, WIRE_VARINT, buf);
    buf.push(1);
}

fn write_string_field(field_number: u32, value: &str, buf: &mut Vec<u8>) {
    if value.is_empty() {
        return;
    }
    write_tag(field_number, WIRE_LENGTH_DELIMITED, buf);
    write_varint_u32(value.len() as u32, buf);
    buf.extend_from_slice(value.as_bytes());
}

fn read_u32_field(wire_type: u32, bytes: &[u8], offset: &mut usize) -> io::Result<u32> {
    if wire_type != WIRE_VARINT {
        return Err(Error::new(ErrorKind::InvalidData, "expected varint for u32"));
    }
    read_varint_u32(bytes, offset)
}

fn read_u64_field(wire_type: u32, bytes: &[u8], offset: &mut usize) -> io::Result<u64> {
    if wire_type != WIRE_VARINT {
        return Err(Error::new(ErrorKind::InvalidData, "expected varint for u64"));
    }
    read_varint_u64(bytes, offset)
}

fn read_bool_field(wire_type: u32, bytes: &[u8], offset: &mut usize) -> io::Result<bool> {
    if wire_type != WIRE_VARINT {
        return Err(Error::new(ErrorKind::InvalidData, "expected varint for bool"));
    }
    let v = read_varint_u32(bytes, offset)?;
    Ok(v != 0)
}

fn read_string_field(
    wire_type: u32,
    bytes: &[u8],
    offset: &mut usize,
) -> io::Result<String> {
    if wire_type != WIRE_LENGTH_DELIMITED {
        return Err(Error::new(
            ErrorKind::InvalidData,
            "expected length-delimited for string",
        ));
    }
    let len = read_varint_u32(bytes, offset)? as usize;
    if *offset + len > bytes.len() {
        return Err(Error::new(ErrorKind::InvalidData, "truncated string field"));
    }
    let s = String::from_utf8(bytes[*offset..*offset + len].to_vec())
        .map_err(|e| Error::new(ErrorKind::InvalidData, format!("invalid utf8: {e}")))?;
    *offset += len;
    Ok(s)
}

// ============================================================================
// Native structs
// ============================================================================

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct SessionHandShake {
    pub banner: String,
    pub auth_type: u8,
    pub session_id: u32,
    pub connect_key: String,
    pub buf: String,
    pub version: String,
}

#[derive(Debug, Default, PartialEq, Eq)]
pub struct PayloadProtect {
    pub channel_id: u32,
    pub command_flag: u32,
    pub check_sum: u8,
    pub v_code: u8,
}

#[derive(Debug, Default, PartialEq, Eq)]
pub struct PayloadHead {
    pub flag: [u8; 2],
    pub reserve: [u8; 2],
    pub protocol_ver: u8,
    pub head_size: u16,
    pub data_size: u32,
}

#[derive(Debug, Default, PartialEq, Eq, Clone)]
pub struct UartHead {
    pub flag: [u8; 2],
    pub option: u16,
    pub session_id: u32,
    pub data_size: u32,
    pub package_index: u32,
    pub data_checksum: u32,
    pub head_checksum: u32,
}

#[derive(Debug, Default, PartialEq, Eq)]
pub struct UsbHead {
    pub flag: [u8; 2],
    pub option: u8,
    pub session_id: u32,
    pub data_size: u32,
}

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct TransferConfig {
    pub file_size: u64,
    pub atime: u64,
    pub mtime: u64,
    pub options: String,
    pub path: String,
    pub optional_name: String,
    pub update_if_new: bool,
    pub compress_type: u8,
    pub hold_timestamp: bool,
    pub function_name: String,
    pub client_cwd: String,
    pub reserve1: String,
    pub reserve2: String,
}

#[derive(Debug, Default, PartialEq, Eq)]
pub struct FileMode {
    pub perm: u64,
    pub u_id: u64,
    pub g_id: u64,
    pub context: String,
    pub full_name: String,
}

#[derive(Debug, Default, PartialEq, Eq)]
pub struct TransferPayload {
    pub index: u64,
    pub compress_type: u8,
    pub compress_size: u32,
    pub uncompress_size: u32,
}

// ============================================================================
// Serialization traits
// ============================================================================

pub trait HdcSerialize {
    fn serialize(&self) -> Vec<u8>;
}

pub trait HdcDeserialize: Sized {
    fn deserialize(bytes: &[u8]) -> io::Result<Self>;
}

// ============================================================================
// Fixed-size structure implementations
// ============================================================================

impl HdcSerialize for PayloadHead {
    fn serialize(&self) -> Vec<u8> {
        let mut buf = Vec::with_capacity(11);
        buf.extend_from_slice(&self.flag);
        buf.extend_from_slice(&self.reserve);
        buf.push(self.protocol_ver);
        buf.extend_from_slice(&self.head_size.to_be_bytes());
        buf.extend_from_slice(&self.data_size.to_be_bytes());
        buf
    }
}

impl HdcDeserialize for PayloadHead {
    fn deserialize(bytes: &[u8]) -> io::Result<Self> {
        if bytes.len() < 11 {
            return Err(Error::new(ErrorKind::InvalidData, "PayloadHead too short"));
        }
        Ok(PayloadHead {
            flag: [bytes[0], bytes[1]],
            reserve: [bytes[2], bytes[3]],
            protocol_ver: bytes[4],
            head_size: u16::from_be_bytes([bytes[5], bytes[6]]),
            data_size: u32::from_be_bytes([bytes[7], bytes[8], bytes[9], bytes[10]]),
        })
    }
}

impl HdcSerialize for UsbHead {
    fn serialize(&self) -> Vec<u8> {
        let mut buf = Vec::with_capacity(11);
        buf.extend_from_slice(&self.flag);
        buf.push(self.option);
        buf.extend_from_slice(&self.session_id.to_be_bytes());
        buf.extend_from_slice(&self.data_size.to_be_bytes());
        buf
    }
}

impl HdcDeserialize for UsbHead {
    fn deserialize(bytes: &[u8]) -> io::Result<Self> {
        if bytes.len() < 11 {
            return Err(Error::new(ErrorKind::InvalidData, "UsbHead too short"));
        }
        Ok(UsbHead {
            flag: [bytes[0], bytes[1]],
            option: bytes[2],
            session_id: u32::from_be_bytes([bytes[3], bytes[4], bytes[5], bytes[6]]),
            data_size: u32::from_be_bytes([bytes[7], bytes[8], bytes[9], bytes[10]]),
        })
    }
}

impl HdcSerialize for UartHead {
    fn serialize(&self) -> Vec<u8> {
        let mut buf = Vec::with_capacity(24);
        buf.extend_from_slice(&self.flag);
        buf.extend_from_slice(&self.option.to_be_bytes());
        buf.extend_from_slice(&self.session_id.to_be_bytes());
        buf.extend_from_slice(&self.data_size.to_be_bytes());
        buf.extend_from_slice(&self.package_index.to_be_bytes());
        buf.extend_from_slice(&self.data_checksum.to_be_bytes());
        buf.extend_from_slice(&self.head_checksum.to_be_bytes());
        buf
    }
}

impl HdcDeserialize for UartHead {
    fn deserialize(bytes: &[u8]) -> io::Result<Self> {
        if bytes.len() < 24 {
            return Err(Error::new(ErrorKind::InvalidData, "UartHead too short"));
        }
        Ok(UartHead {
            flag: [bytes[0], bytes[1]],
            option: u16::from_be_bytes([bytes[2], bytes[3]]),
            session_id: u32::from_be_bytes([bytes[4], bytes[5], bytes[6], bytes[7]]),
            data_size: u32::from_be_bytes([bytes[8], bytes[9], bytes[10], bytes[11]]),
            package_index: u32::from_be_bytes([bytes[12], bytes[13], bytes[14], bytes[15]]),
            data_checksum: u32::from_be_bytes([bytes[16], bytes[17], bytes[18], bytes[19]]),
            head_checksum: u32::from_be_bytes([bytes[20], bytes[21], bytes[22], bytes[23]]),
        })
    }
}

// ============================================================================
// TLV structure implementations (protobuf-like)
// ============================================================================

impl HdcSerialize for SessionHandShake {
    fn serialize(&self) -> Vec<u8> {
        let mut buf = Vec::new();
        write_string_field(1, &self.banner, &mut buf);
        // Always write authType to match C++ behavior (even when 0)
        write_tag(2, WIRE_VARINT, &mut buf);
        buf.push(self.auth_type);
        if self.session_id != 0 {
            write_u32_field(3, self.session_id, &mut buf);
        }
        write_string_field(4, &self.connect_key, &mut buf);
        write_string_field(5, &self.buf, &mut buf);
        write_string_field(6, &self.version, &mut buf);
        buf
    }
}

impl HdcDeserialize for SessionHandShake {
    fn deserialize(bytes: &[u8]) -> io::Result<Self> {
        let mut result = SessionHandShake::default();
        let mut offset = 0;
        while offset < bytes.len() {
            let tag_key = read_varint_u32(bytes, &mut offset)?;
            let (field_number, wire_type) = read_tag_wire_type(tag_key);
            match field_number {
                1 => result.banner = read_string_field(wire_type, bytes, &mut offset)?,
                2 => {
                    if wire_type != WIRE_VARINT {
                        return Err(Error::new(ErrorKind::InvalidData, "bad wire type for auth_type"));
                    }
                    result.auth_type = read_varint_u32(bytes, &mut offset)? as u8;
                }
                3 => result.session_id = read_u32_field(wire_type, bytes, &mut offset)?,
                4 => result.connect_key = read_string_field(wire_type, bytes, &mut offset)?,
                5 => result.buf = read_string_field(wire_type, bytes, &mut offset)?,
                6 => result.version = read_string_field(wire_type, bytes, &mut offset)?,
                _ => {
                    // skip unknown field
                    match wire_type {
                        WIRE_VARINT => {
                            read_varint_u64(bytes, &mut offset)?;
                        }
                        WIRE_FIXED64 => {
                            offset += 8;
                        }
                        WIRE_LENGTH_DELIMITED => {
                            let len = read_varint_u32(bytes, &mut offset)? as usize;
                            offset += len;
                        }
                        WIRE_FIXED32 => {
                            offset += 4;
                        }
                        _ => return Err(Error::new(ErrorKind::InvalidData, "unknown wire type")),
                    }
                }
            }
        }
        Ok(result)
    }
}

impl HdcSerialize for PayloadProtect {
    fn serialize(&self) -> Vec<u8> {
        let mut buf = Vec::new();
        if self.channel_id != 0 {
            write_u32_field(1, self.channel_id, &mut buf);
        }
        if self.command_flag != 0 {
            write_u32_field(2, self.command_flag, &mut buf);
        }
        if self.check_sum != 0 {
            write_tag(3, WIRE_VARINT, &mut buf);
            buf.push(self.check_sum);
        }
        if self.v_code != 0 {
            write_tag(4, WIRE_VARINT, &mut buf);
            buf.push(self.v_code);
        }
        buf
    }
}

impl HdcDeserialize for PayloadProtect {
    fn deserialize(bytes: &[u8]) -> io::Result<Self> {
        let mut result = PayloadProtect::default();
        let mut offset = 0;
        while offset < bytes.len() {
            let tag_key = read_varint_u32(bytes, &mut offset)?;
            let (field_number, wire_type) = read_tag_wire_type(tag_key);
            match field_number {
                1 => result.channel_id = read_u32_field(wire_type, bytes, &mut offset)?,
                2 => result.command_flag = read_u32_field(wire_type, bytes, &mut offset)?,
                3 => {
                    if wire_type != WIRE_VARINT {
                        return Err(Error::new(ErrorKind::InvalidData, "bad wire type for check_sum"));
                    }
                    result.check_sum = read_varint_u32(bytes, &mut offset)? as u8;
                }
                4 => {
                    if wire_type != WIRE_VARINT {
                        return Err(Error::new(ErrorKind::InvalidData, "bad wire type for v_code"));
                    }
                    result.v_code = read_varint_u32(bytes, &mut offset)? as u8;
                }
                _ => {
                    match wire_type {
                        WIRE_VARINT => {
                            read_varint_u64(bytes, &mut offset)?;
                        }
                        WIRE_FIXED64 => {
                            offset += 8;
                        }
                        WIRE_LENGTH_DELIMITED => {
                            let len = read_varint_u32(bytes, &mut offset)? as usize;
                            offset += len;
                        }
                        WIRE_FIXED32 => {
                            offset += 4;
                        }
                        _ => return Err(Error::new(ErrorKind::InvalidData, "unknown wire type")),
                    }
                }
            }
        }
        Ok(result)
    }
}

impl HdcSerialize for TransferConfig {
    fn serialize(&self) -> Vec<u8> {
        let mut buf = Vec::new();
        write_u64_field(1, self.file_size, &mut buf);
        write_u64_field(2, self.atime, &mut buf);
        write_u64_field(3, self.mtime, &mut buf);
        write_string_field(4, &self.options, &mut buf);
        write_string_field(5, &self.path, &mut buf);
        write_string_field(6, &self.optional_name, &mut buf);
        write_bool_field(7, self.update_if_new, &mut buf);
        if self.compress_type != 0 {
            write_tag(8, WIRE_VARINT, &mut buf);
            buf.push(self.compress_type);
        }
        write_bool_field(9, self.hold_timestamp, &mut buf);
        write_string_field(10, &self.function_name, &mut buf);
        write_string_field(11, &self.client_cwd, &mut buf);
        write_string_field(12, &self.reserve1, &mut buf);
        write_string_field(13, &self.reserve2, &mut buf);
        buf
    }
}

impl HdcDeserialize for TransferConfig {
    fn deserialize(bytes: &[u8]) -> io::Result<Self> {
        let mut result = TransferConfig::default();
        let mut offset = 0;
        while offset < bytes.len() {
            let tag_key = read_varint_u32(bytes, &mut offset)?;
            let (field_number, wire_type) = read_tag_wire_type(tag_key);
            match field_number {
                1 => result.file_size = read_u64_field(wire_type, bytes, &mut offset)?,
                2 => result.atime = read_u64_field(wire_type, bytes, &mut offset)?,
                3 => result.mtime = read_u64_field(wire_type, bytes, &mut offset)?,
                4 => result.options = read_string_field(wire_type, bytes, &mut offset)?,
                5 => result.path = read_string_field(wire_type, bytes, &mut offset)?,
                6 => result.optional_name = read_string_field(wire_type, bytes, &mut offset)?,
                7 => result.update_if_new = read_bool_field(wire_type, bytes, &mut offset)?,
                8 => {
                    if wire_type != WIRE_VARINT {
                        return Err(Error::new(
                            ErrorKind::InvalidData,
                            "bad wire type for compress_type",
                        ));
                    }
                    result.compress_type = read_varint_u32(bytes, &mut offset)? as u8;
                }
                9 => result.hold_timestamp = read_bool_field(wire_type, bytes, &mut offset)?,
                10 => result.function_name = read_string_field(wire_type, bytes, &mut offset)?,
                11 => result.client_cwd = read_string_field(wire_type, bytes, &mut offset)?,
                12 => result.reserve1 = read_string_field(wire_type, bytes, &mut offset)?,
                13 => result.reserve2 = read_string_field(wire_type, bytes, &mut offset)?,
                _ => {
                    match wire_type {
                        WIRE_VARINT => {
                            read_varint_u64(bytes, &mut offset)?;
                        }
                        WIRE_FIXED64 => {
                            offset += 8;
                        }
                        WIRE_LENGTH_DELIMITED => {
                            let len = read_varint_u32(bytes, &mut offset)? as usize;
                            offset += len;
                        }
                        WIRE_FIXED32 => {
                            offset += 4;
                        }
                        _ => return Err(Error::new(ErrorKind::InvalidData, "unknown wire type")),
                    }
                }
            }
        }
        Ok(result)
    }
}

impl HdcSerialize for FileMode {
    fn serialize(&self) -> Vec<u8> {
        let mut buf = Vec::new();
        write_u64_field(1, self.perm, &mut buf);
        write_u64_field(2, self.u_id, &mut buf);
        write_u64_field(3, self.g_id, &mut buf);
        write_string_field(4, &self.context, &mut buf);
        write_string_field(5, &self.full_name, &mut buf);
        buf
    }
}

impl HdcDeserialize for FileMode {
    fn deserialize(bytes: &[u8]) -> io::Result<Self> {
        let mut result = FileMode::default();
        let mut offset = 0;
        while offset < bytes.len() {
            let tag_key = read_varint_u32(bytes, &mut offset)?;
            let (field_number, wire_type) = read_tag_wire_type(tag_key);
            match field_number {
                1 => result.perm = read_u64_field(wire_type, bytes, &mut offset)?,
                2 => result.u_id = read_u64_field(wire_type, bytes, &mut offset)?,
                3 => result.g_id = read_u64_field(wire_type, bytes, &mut offset)?,
                4 => result.context = read_string_field(wire_type, bytes, &mut offset)?,
                5 => result.full_name = read_string_field(wire_type, bytes, &mut offset)?,
                _ => {
                    match wire_type {
                        WIRE_VARINT => {
                            read_varint_u64(bytes, &mut offset)?;
                        }
                        WIRE_FIXED64 => {
                            offset += 8;
                        }
                        WIRE_LENGTH_DELIMITED => {
                            let len = read_varint_u32(bytes, &mut offset)? as usize;
                            offset += len;
                        }
                        WIRE_FIXED32 => {
                            offset += 4;
                        }
                        _ => return Err(Error::new(ErrorKind::InvalidData, "unknown wire type")),
                    }
                }
            }
        }
        Ok(result)
    }
}

impl HdcSerialize for TransferPayload {
    fn serialize(&self) -> Vec<u8> {
        let mut buf = Vec::new();
        write_u64_field(1, self.index, &mut buf);
        if self.compress_type != 0 {
            write_tag(2, WIRE_VARINT, &mut buf);
            buf.push(self.compress_type);
        }
        if self.compress_size != 0 {
            write_u32_field(3, self.compress_size, &mut buf);
        }
        if self.uncompress_size != 0 {
            write_u32_field(4, self.uncompress_size, &mut buf);
        }
        buf
    }
}

impl HdcDeserialize for TransferPayload {
    fn deserialize(bytes: &[u8]) -> io::Result<Self> {
        let mut result = TransferPayload::default();
        let mut offset = 0;
        while offset < bytes.len() {
            let tag_key = read_varint_u32(bytes, &mut offset)?;
            let (field_number, wire_type) = read_tag_wire_type(tag_key);
            match field_number {
                1 => result.index = read_u64_field(wire_type, bytes, &mut offset)?,
                2 => {
                    if wire_type != WIRE_VARINT {
                        return Err(Error::new(
                            ErrorKind::InvalidData,
                            "bad wire type for compress_type",
                        ));
                    }
                    result.compress_type = read_varint_u32(bytes, &mut offset)? as u8;
                }
                3 => result.compress_size = read_u32_field(wire_type, bytes, &mut offset)?,
                4 => result.uncompress_size = read_u32_field(wire_type, bytes, &mut offset)?,
                _ => {
                    match wire_type {
                        WIRE_VARINT => {
                            read_varint_u64(bytes, &mut offset)?;
                        }
                        WIRE_FIXED64 => {
                            offset += 8;
                        }
                        WIRE_LENGTH_DELIMITED => {
                            let len = read_varint_u32(bytes, &mut offset)? as usize;
                            offset += len;
                        }
                        WIRE_FIXED32 => {
                            offset += 4;
                        }
                        _ => return Err(Error::new(ErrorKind::InvalidData, "unknown wire type")),
                    }
                }
            }
        }
        Ok(result)
    }
}

// ============================================================================
// Packet assembly helpers
// ============================================================================

pub const HEAD_SIZE: usize = 11; // sizeof(PayloadHead)
pub const USB_HEAD_SIZE: usize = 11; // sizeof(UsbHead)
pub const UART_HEAD_SIZE: usize = 24; // sizeof(UartHead)

pub fn concat_pack(msg: &TaskMessage) -> Vec<u8> {
    let check_sum: u8 = if ENABLE_IO_CHECK {
        msg.payload.iter().sum()
    } else {
        0
    };

    let payload_protect = PayloadProtect {
        channel_id: msg.channel_id,
        command_flag: msg.command.as_u32(),
        check_sum,
        v_code: PAYLOAD_VCODE,
    };
    let protect_buf = payload_protect.serialize();

    let payload_head = PayloadHead {
        flag: [PACKET_FLAG[0], PACKET_FLAG[1]],
        reserve: [0, 0],
        protocol_ver: VER_PROTOCOL as u8,
        head_size: protect_buf.len() as u16,
        data_size: msg.payload.len() as u32,
    };
    let head_buf = payload_head.serialize();

    let mut result = Vec::with_capacity(head_buf.len() + protect_buf.len() + msg.payload.len());
    result.extend_from_slice(&head_buf);
    result.extend_from_slice(&protect_buf);
    result.extend_from_slice(&msg.payload);
    result
}

pub fn unpack_payload_head(data: &[u8]) -> io::Result<PayloadHead> {
    if data.len() < HEAD_SIZE {
        return Err(Error::new(ErrorKind::InvalidData, "payload head too short"));
    }
    let head = PayloadHead::deserialize(&data[..HEAD_SIZE])?;
    if head.flag != [PACKET_FLAG[0], PACKET_FLAG[1]] {
        return Err(Error::new(
            ErrorKind::InvalidData,
            format!(
                "PACKET_FLAG incorrect: expected {:?}, got {:?}",
                PACKET_FLAG, head.flag
            ),
        ));
    }
    Ok(head)
}

pub fn unpack_payload_protect(data: &[u8]) -> io::Result<PayloadProtect> {
    PayloadProtect::deserialize(data)
}

pub fn unpack_task_message(data: &[u8]) -> io::Result<TaskMessage> {
    if data.len() < HEAD_SIZE {
        return Err(Error::new(ErrorKind::InvalidData, "data too short for head"));
    }
    let head = unpack_payload_head(&data[..HEAD_SIZE])?;
    let expected_head_size = head.head_size as usize;
    let expected_data_size = head.data_size as usize;

    if expected_head_size + expected_data_size == 0
        || expected_head_size + expected_data_size > HDC_BUF_MAX_SIZE
    {
        return Err(Error::new(ErrorKind::InvalidData, "Packet size incorrect"));
    }

    if HEAD_SIZE + expected_head_size + expected_data_size > data.len() {
        return Err(Error::new(ErrorKind::InvalidData, "incomplete packet"));
    }

    let protect_data = &data[HEAD_SIZE..HEAD_SIZE + expected_head_size];
    let payload_data = &data[HEAD_SIZE + expected_head_size..HEAD_SIZE + expected_head_size + expected_data_size];

    let payload_protect = unpack_payload_protect(protect_data)?;
    if payload_protect.v_code != PAYLOAD_VCODE {
        return Err(Error::new(
            ErrorKind::InvalidData,
            "Session recv static vcode failed",
        ));
    }

    let command = HdcCommand::try_from(payload_protect.command_flag)
        .map_err(|_| Error::new(ErrorKind::InvalidData, "unknown command"))?;

    Ok(TaskMessage {
        channel_id: payload_protect.channel_id,
        command,
        payload: payload_data.to_vec(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_payload_head_roundtrip() {
        let head = PayloadHead {
            flag: *b"HW",
            reserve: [0, 0],
            protocol_ver: 1,
            head_size: 10u16,
            data_size: 100u32,
        };
        let bytes = head.serialize();
        assert_eq!(bytes.len(), HEAD_SIZE);
        let head2 = PayloadHead::deserialize(&bytes).unwrap();
        assert_eq!(head, head2);
    }

    #[test]
    fn test_usb_head_roundtrip() {
        let head = UsbHead {
            flag: *b"UB",
            option: 1,
            session_id: 0x12345678,
            data_size: 0xabcdef00,
        };
        let bytes = head.serialize();
        assert_eq!(bytes.len(), USB_HEAD_SIZE);
        let head2 = UsbHead::deserialize(&bytes).unwrap();
        assert_eq!(head, head2);
    }

    #[test]
    fn test_uart_head_roundtrip() {
        let head = UartHead {
            flag: *b"UB",
            option: 0x1234,
            session_id: 0xdeadbeef,
            data_size: 0x11223344,
            package_index: 0x55667788,
            data_checksum: 0xaabbccdd,
            head_checksum: 0xeeff0011,
        };
        let bytes = head.serialize();
        assert_eq!(bytes.len(), UART_HEAD_SIZE);
        let head2 = UartHead::deserialize(&bytes).unwrap();
        assert_eq!(head, head2);
    }

    #[test]
    fn test_session_handshake_roundtrip() {
        let shs = SessionHandShake {
            banner: "OHOS HDC".to_string(),
            auth_type: 1,
            session_id: 12345,
            connect_key: "test-device".to_string(),
            buf: "some-buf".to_string(),
            version: "Ver: 3.0.0b".to_string(),
        };
        let bytes = shs.serialize();
        let shs2 = SessionHandShake::deserialize(&bytes).unwrap();
        assert_eq!(shs, shs2);
    }

    #[test]
    fn test_payload_protect_roundtrip() {
        let pp = PayloadProtect {
            channel_id: 42,
            command_flag: 1001,
            check_sum: 0,
            v_code: 0x09,
        };
        let bytes = pp.serialize();
        let pp2 = PayloadProtect::deserialize(&bytes).unwrap();
        assert_eq!(pp, pp2);
    }

    #[test]
    fn test_transfer_config_roundtrip() {
        let tc = TransferConfig {
            file_size: 1024,
            atime: 1234567890,
            mtime: 9876543210,
            options: "-r".to_string(),
            path: "/data/local/tmp".to_string(),
            optional_name: "test.txt".to_string(),
            update_if_new: true,
            compress_type: 1,
            hold_timestamp: false,
            function_name: "install".to_string(),
            client_cwd: "/home/user".to_string(),
            reserve1: "".to_string(),
            reserve2: "".to_string(),
        };
        let bytes = tc.serialize();
        let tc2 = TransferConfig::deserialize(&bytes).unwrap();
        assert_eq!(tc, tc2);
    }

    #[test]
    fn test_file_mode_roundtrip() {
        let fm = FileMode {
            perm: 0o644,
            u_id: 1000,
            g_id: 1000,
            context: "u:object_r:app_data_file:s0".to_string(),
            full_name: "/data/app/test.hap".to_string(),
        };
        let bytes = fm.serialize();
        let fm2 = FileMode::deserialize(&bytes).unwrap();
        assert_eq!(fm, fm2);
    }

    #[test]
    fn test_transfer_payload_roundtrip() {
        let tp = TransferPayload {
            index: 0,
            compress_type: 1,
            compress_size: 512,
            uncompress_size: 1024,
        };
        let bytes = tp.serialize();
        let tp2 = TransferPayload::deserialize(&bytes).unwrap();
        assert_eq!(tp, tp2);
    }

    #[test]
    fn test_concat_and_unpack() {
        let msg = TaskMessage {
            channel_id: 1,
            command: HdcCommand::UnityExecute,
            payload: b"hello world".to_vec(),
        };
        let packed = concat_pack(&msg);
        let unpacked = unpack_task_message(&packed).unwrap();
        assert_eq!(msg.channel_id, unpacked.channel_id);
        assert_eq!(msg.command, unpacked.command);
        assert_eq!(msg.payload, unpacked.payload);
    }
}
