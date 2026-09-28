//! TCP transport layer for HDC host.

use hdc_protocol::config::{HDC_BUF_MAX_SIZE, TaskMessage};
use hdc_protocol::serializer::{HEAD_SIZE, unpack_payload_head, unpack_payload_protect};
use hdc_protocol::config::HdcCommand;
use std::io::{self, Error, ErrorKind};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpStream, tcp::{OwnedReadHalf, OwnedWriteHalf}};

/// Read an exact number of bytes from the TCP stream.
pub async fn read_frame(rd: &mut OwnedReadHalf, expected_size: usize) -> io::Result<Vec<u8>> {
    if expected_size == 0 {
        return Ok(vec![]);
    }
    let mut data = vec![0u8; expected_size];
    let mut index = 0;
    while index < expected_size {
        match rd.read(&mut data[index..]).await {
            Ok(0) => {
                return Err(Error::new(ErrorKind::ConnectionAborted, "peer shutdown"));
            }
            Ok(n) => {
                index += n;
            }
            Err(e) => {
                return Err(Error::new(ErrorKind::Other, format!("read tcp failed: {e}")));
            }
        }
    }
    Ok(data)
}

/// Unpack a TaskMessage from a TCP stream.
pub async fn unpack_task_message(rd: &mut OwnedReadHalf) -> io::Result<TaskMessage> {
    let data = read_frame(rd, HEAD_SIZE).await?;
    let payload_head = unpack_payload_head(&data)?;

    let expected_head_size = payload_head.head_size as usize;
    let expected_data_size = payload_head.data_size as usize;

    if expected_head_size + expected_data_size == 0
        || expected_head_size + expected_data_size > HDC_BUF_MAX_SIZE
    {
        return Err(Error::new(ErrorKind::InvalidData, "Packet size incorrect"));
    }

    let data = read_frame(rd, expected_head_size).await?;
    let payload_protect = unpack_payload_protect(&data)?;
    let channel_id = payload_protect.channel_id;

    let command = HdcCommand::try_from(payload_protect.command_flag)
        .map_err(|_| Error::new(ErrorKind::InvalidData, "unknown command"))?;

    let payload = read_frame(rd, expected_data_size).await?;
    Ok(TaskMessage {
        channel_id,
        command,
        payload,
    })
}

/// Read a channel message (4-byte length prefix + payload).
pub async fn recv_channel_message(rd: &mut OwnedReadHalf) -> io::Result<Vec<u8>> {
    let data = read_frame(rd, 4).await?;
    let expected_size = u32::from_be_bytes([data[0], data[1], data[2], data[3]]) as usize;
    read_frame(rd, expected_size).await
}

/// Write a channel message (4-byte length prefix + payload).
pub async fn send_channel_message(wr: &mut OwnedWriteHalf, data: &[u8]) -> io::Result<()> {
    let len_bytes = (data.len() as u32).to_be_bytes();
    wr.write_all(&len_bytes).await?;
    wr.write_all(data).await?;
    Ok(())
}
