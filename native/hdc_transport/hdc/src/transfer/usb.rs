//! USB transport layer for HDC host.
//!
//! Uses async libusb transfers via AsyncUsbConnection, eliminating the
//! Mutex bottleneck and enabling concurrent infinite-timeout reads and writes.

use hdc_protocol::config::{
    HdcCommand, TaskMessage, HDC_BUF_MAX_SIZE, USB_OPTION_HEADER, USB_OPTION_RESET, USB_PACKET_FLAG,
};
use hdc_protocol::serializer::{
    HEAD_SIZE, USB_HEAD_SIZE, UsbHead, concat_pack, unpack_payload_head, unpack_payload_protect,
};
use hdc_protocol::{HdcDeserialize, HdcSerialize};
use crate::usb::AsyncUsbConnection;
use std::io::{self, Error, ErrorKind};

/// Read an exact number of bytes from USB bulk endpoint.
/// Uses async bulk transfers with optional timeout (0 = infinite).
pub async fn read_exact_from_usb(
    conn: &AsyncUsbConnection,
    endpoint: u8,
    expected_size: usize,
    timeout_ms: u32,
) -> io::Result<Vec<u8>> {
    if expected_size == 0 {
        return Ok(vec![]);
    }
    let mut data = vec![0u8; expected_size];
    let mut index = 0;
    while index < expected_size {
        let to_read = expected_size - index;
        // For the first read use the caller's timeout; subsequent partial reads
        // use a short timeout so we don't hang forever if the stream breaks.
        let read_timeout = if index == 0 { timeout_ms } else { 5000 };
        let n = conn.read_bulk(endpoint, &mut data[index..index + to_read], read_timeout).await?;
        if n == 0 {
            return Err(Error::new(ErrorKind::ConnectionAborted, "USB peer shutdown"));
        }
        index += n;
    }
    Ok(data)
}

/// Drop up to `buf_size` bytes from the USB bulk IN endpoint.
/// Returns the number of bytes actually dropped.
pub async fn read_usb_drop(
    conn: &AsyncUsbConnection,
    endpoint: u8,
    buf_size: usize,
) -> io::Result<usize> {
    let mut buf = vec![0u8; buf_size];
    conn.read_bulk(endpoint, &mut buf, 500).await
}

/// Build a USB packet header.
pub fn build_usb_header(session_id: u32, option: u8, data_size: u32) -> Vec<u8> {
    let head = UsbHead {
        flag: [USB_PACKET_FLAG[0], USB_PACKET_FLAG[1]],
        option,
        session_id,
        data_size,
    };
    head.serialize()
}

/// Send a soft-reset packet to daemon via USB.
pub async fn send_usb_soft_reset(
    conn: &AsyncUsbConnection,
    endpoint: u8,
    session_id: u32,
) -> io::Result<()> {
    let header = build_usb_header(session_id, USB_OPTION_RESET, 0);
    tracing::info!("send_usb_soft_reset: writing {} bytes", header.len());
    conn.write_bulk(endpoint, &header, 5000).await?;
    tracing::info!("send_usb_soft_reset: write done");
    Ok(())
}

/// Send raw HDC payload bytes via USB (header + payload) as separate bulk transfers.
/// HDC USB protocol requires header and payload to be sent as separate USB
/// transfers so the daemon can identify the header by its exact 11-byte size.
pub async fn send_usb_raw(
    conn: &AsyncUsbConnection,
    endpoint: u8,
    session_id: u32,
    payload: &[u8],
    max_packet_size: u16,
) -> io::Result<()> {
    let payload_len = payload.len();

    // 1) Send USB header (11 bytes) as its own transfer
    let header = build_usb_header(session_id, USB_OPTION_HEADER, payload_len as u32);
    tracing::info!("send_usb_raw: writing header {} bytes", header.len());
    conn.write_bulk(endpoint, &header, 30000).await?;
    tracing::info!("send_usb_raw: header written");

    // 2) Send payload as a separate transfer
    if !payload.is_empty() {
        tracing::info!("send_usb_raw: writing payload {} bytes", payload.len());
        conn.write_bulk(endpoint, payload, 30000).await?;
        tracing::info!("send_usb_raw: payload written");
    }

    // 3) If payload is an exact multiple of max_packet_size, send a dummy header
    // as a separate transfer so the daemon sees a short packet and knows the
    // message is complete.
    if payload_len > 0 && (payload_len % max_packet_size as usize == 0) {
        let dummy = build_usb_header(session_id, 0, 0);
        tracing::info!("send_usb_raw: writing dummy header {} bytes", dummy.len());
        conn.write_bulk(endpoint, &dummy, 30000).await?;
        tracing::info!("send_usb_raw: dummy header written");
    }

    Ok(())
}

/// Send a complete HDC message via USB (header + payload).
pub async fn send_usb_message(
    conn: &AsyncUsbConnection,
    endpoint: u8,
    session_id: u32,
    msg: &TaskMessage,
    max_packet_size: u16,
) -> io::Result<()> {
    let payload = concat_pack(msg);
    send_usb_raw(conn, endpoint, session_id, &payload, max_packet_size).await
}

/// Receive a complete HDC message from USB.
pub async fn recv_usb_message(
    conn: &AsyncUsbConnection,
    endpoint: u8,
) -> io::Result<(u32, TaskMessage)> {
    // Read and parse USBHead
    let head_data = read_exact_from_usb(conn, endpoint, USB_HEAD_SIZE, 0).await?; // 0 = infinite timeout
    tracing::info!("recv_usb_message: head={:02x?}", head_data);
    let usb_head = UsbHead::deserialize(&head_data)?;
    let session_id = usb_head.session_id;
    let data_size = usb_head.data_size as usize;
    let option = usb_head.option;
    tracing::info!("recv_usb_message: session_id={session_id}, data_size={data_size}, option={option}");

    // Handle special packets (reset, dummy/ZLP)
    if data_size == 0 {
        return Err(Error::new(ErrorKind::InvalidData, "USB nop/reset packet"));
    }

    if (option & USB_OPTION_HEADER) == 0 {
        return Err(Error::new(
            ErrorKind::InvalidData,
            format!("USB packet without HEADER option: {option}"),
        ));
    }

    if data_size > HDC_BUF_MAX_SIZE as usize {
        return Err(Error::new(ErrorKind::InvalidData, "USB payload too large"));
    }

    // Read the actual payload (PayloadHead + PayloadProtect + Payload)
    let payload_data = read_exact_from_usb(conn, endpoint, data_size, 0).await?;
    tracing::info!("recv_usb_message: payload={:02x?} ({} bytes)", payload_data, payload_data.len());

    // Parse PayloadHead
    if payload_data.len() < HEAD_SIZE {
        return Err(Error::new(ErrorKind::InvalidData, "payload too short for head"));
    }
    let payload_head = unpack_payload_head(&payload_data[..HEAD_SIZE])?;
    let expected_head_size = payload_head.head_size as usize;
    let expected_data_size = payload_head.data_size as usize;

    if HEAD_SIZE + expected_head_size + expected_data_size > payload_data.len() {
        return Err(Error::new(ErrorKind::InvalidData, "incomplete payload"));
    }

    // Parse PayloadProtect
    let protect_data = &payload_data[HEAD_SIZE..HEAD_SIZE + expected_head_size];
    let payload_protect = unpack_payload_protect(protect_data)?;
    let channel_id = payload_protect.channel_id;

    let command = HdcCommand::try_from(payload_protect.command_flag)
        .map_err(|_| Error::new(ErrorKind::InvalidData, "unknown command"))?;

    // Extract Payload
    let payload = &payload_data[HEAD_SIZE + expected_head_size..HEAD_SIZE + expected_head_size + expected_data_size];

    Ok((session_id, TaskMessage {
        channel_id,
        command,
        payload: payload.to_vec(),
    }))
}
