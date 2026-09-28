//! Simplified PSK-encrypted TCP framing for HDC.
//!
//! This is a pragmatic Rust replacement for the official OpenSSL TLS-PSK
//! encrypted TCP channel.  It is **not** wire-compatible with the official
//! C++ implementation, but it provides confidentiality/integrity for the
//! hdc <-> hdcd TCP link when both sides enable `OHOS_HDC_ENCRYPT_CHANNEL=1`.
//!
//! Frame format on the wire (after the plain 4-byte length prefix):
//!   [8-byte BE counter][ciphertext = AES-128-GCM(plaintext HDC frame)]
//! The 16-byte GCM authentication tag is appended to the ciphertext.

use aes_gcm::{
    aead::{Aead, KeyInit},
    Aes128Gcm,
};
use aes_gcm::aead::generic_array::GenericArray;
use rand::RngCore;

const KEY_LEN: usize = 16;
const NONCE_LEN: usize = 12;
const TAG_LEN: usize = 16;

/// Symmetric cipher used after the PSK has been exchanged.
#[derive(Clone)]
pub struct PskCipher {
    send_key: [u8; KEY_LEN],
    recv_key: [u8; KEY_LEN],
    send_counter: u64,
    recv_counter: u64,
}

impl PskCipher {
    /// Create a cipher from a 32-byte pre-shared key.
    ///
    /// * `is_host` = true:  host->daemon uses `psk[0..16]`, daemon->host uses `psk[16..32]`.
    /// * `is_host` = false: the opposite direction mapping.
    pub fn new(psk: &[u8; 32], is_host: bool) -> Self {
        let mut send_key = [0u8; KEY_LEN];
        let mut recv_key = [0u8; KEY_LEN];
        if is_host {
            send_key.copy_from_slice(&psk[0..KEY_LEN]);
            recv_key.copy_from_slice(&psk[KEY_LEN..KEY_LEN * 2]);
        } else {
            recv_key.copy_from_slice(&psk[0..KEY_LEN]);
            send_key.copy_from_slice(&psk[KEY_LEN..KEY_LEN * 2]);
        }
        Self {
            send_key,
            recv_key,
            send_counter: 0,
            recv_counter: 0,
        }
    }

    /// Generate a random 32-byte PSK.
    pub fn generate_psk() -> [u8; 32] {
        let mut psk = [0u8; 32];
        rand::thread_rng().fill_bytes(&mut psk);
        psk
    }

    /// Encrypt a plaintext HDC frame.  Returns the ciphertext (including GCM tag)
    /// prefixed by the 8-byte counter used for the nonce.
    pub fn encrypt(&mut self, plaintext: &[u8]) -> std::io::Result<Vec<u8>> {
        let cipher = Aes128Gcm::new_from_slice(&self.send_key)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, format!("AES key init: {e:?}")))?;
        let nonce = counter_to_nonce(self.send_counter);
        let ciphertext = cipher
            .encrypt(&nonce, plaintext)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, format!("AES-GCM encrypt: {e:?}")))?;
        let mut out = Vec::with_capacity(8 + ciphertext.len());
        out.extend_from_slice(&self.send_counter.to_be_bytes());
        out.extend_from_slice(&ciphertext);
        self.send_counter = self.send_counter.wrapping_add(1);
        Ok(out)
    }

    /// Decrypt a ciphertext frame produced by `encrypt`.
    pub fn decrypt(&mut self, data: &[u8]) -> std::io::Result<Vec<u8>> {
        if data.len() < 8 + TAG_LEN {
            return Err(std::io::Error::new(std::io::ErrorKind::InvalidData, "encrypted frame too short"));
        }
        let counter = u64::from_be_bytes([data[0], data[1], data[2], data[3], data[4], data[5], data[6], data[7]]);
        let cipher = Aes128Gcm::new_from_slice(&self.recv_key)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, format!("AES key init: {e:?}")))?;
        let nonce = counter_to_nonce(counter);
        let plaintext = cipher
            .decrypt(&nonce, &data[8..])
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, format!("AES-GCM decrypt: {e:?}")))?;
        self.recv_counter = counter.wrapping_add(1);
        Ok(plaintext)
    }
}

fn counter_to_nonce(counter: u64) -> GenericArray<u8, aes_gcm::aead::consts::U12> {
    let mut nonce = [0u8; NONCE_LEN];
    nonce[4..12].copy_from_slice(&counter.to_be_bytes());
    *GenericArray::from_slice(&nonce)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn psk_roundtrip() {
        let psk = PskCipher::generate_psk();
        let mut host = PskCipher::new(&psk, true);
        let mut daemon = PskCipher::new(&psk, false);
        let plain = b"hello hdc encrypted world";
        let ct = host.encrypt(plain).unwrap();
        let out = daemon.decrypt(&ct).unwrap();
        assert_eq!(out, plain);
    }
}
