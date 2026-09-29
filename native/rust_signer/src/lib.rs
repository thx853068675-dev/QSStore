//! In-process HAP signing bridge. No key, profile or certificate is embedded
//! in the application; callers supply paths inside their own sandbox.

use std::ffi::{c_char, CStr};
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::{fs, panic};
use std::time::Duration;

use hapsigner::{
    ApplicationVerifier, HapSigner, InputFormat, ProfileVerifier, SignOptions, SigningAlgorithm,
    SigningKey, SigningMaterial,
};
use memmap2::MmapOptions;
use p256::pkcs8::{DecodePrivateKey, DecodePublicKey, EncodePrivateKey};
use x509_cert::der::{Decode, Encode};
use x509_cert::Certificate;
use zeroize::Zeroizing;

static NEXT_TEMP: AtomicU64 = AtomicU64::new(0);

struct PendingOutput(std::path::PathBuf);

impl PendingOutput {
    fn beside(destination: &Path) -> Result<Self, String> {
        let parent = destination
            .parent()
            .ok_or("output has no parent directory")?;
        let name = destination.file_name().ok_or("output has no file name")?;
        for _ in 0..16 {
            let nonce = NEXT_TEMP.fetch_add(1, Ordering::Relaxed);
            let path = parent.join(format!(
                ".{}.qingqi-{}-{nonce}.hap",
                name.to_string_lossy(),
                std::process::id()
            ));
            match fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&path)
            {
                Ok(_) => return Ok(Self(path)),
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(_) => return Err("cannot create temporary signed HAP".into()),
            }
        }
        Err("cannot allocate temporary signed HAP".into())
    }
}

impl Drop for PendingOutput {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

fn path(value: *const c_char) -> Result<String, String> {
    if value.is_null() {
        return Err("missing signing path".into());
    }
    let text = unsafe { CStr::from_ptr(value) }
        .to_str()
        .map_err(|_| "signing path is not UTF-8")?;
    if text.is_empty() || text.len() > 4096 {
        return Err("invalid signing path".into());
    }
    Ok(text.to_owned())
}

fn first_pem_block<'a>(text: &'a str, kind: &str) -> Result<&'a str, String> {
    let begin = format!("-----BEGIN {kind}-----");
    let end = format!("-----END {kind}-----");
    let start = text
        .find(&begin)
        .ok_or_else(|| format!("{kind} PEM block is missing"))?;
    let finish = text[start..]
        .find(&end)
        .ok_or_else(|| format!("{kind} PEM block is incomplete"))?
        + start
        + end.len();
    Ok(&text[start..finish])
}

fn certificate_public_key(der: &[u8]) -> Result<p256::PublicKey, String> {
    let cert = Certificate::from_der(der).map_err(|_| "invalid certificate DER")?;
    let spki = cert
        .tbs_certificate
        .subject_public_key_info
        .to_der()
        .map_err(|_| "invalid certificate public key")?;
    p256::PublicKey::from_public_key_der(&spki).map_err(|_| "certificate is not P-256".into())
}

fn key_matches_certificate(
    private_key: *const c_char,
    certificate: *const c_char,
) -> Result<bool, String> {
    let key_path = path(private_key)?;
    let cert_path = path(certificate)?;
    let key_pem =
        Zeroizing::new(fs::read_to_string(key_path).map_err(|_| "cannot read private key")?);
    let key_block = first_pem_block(&key_pem, "PRIVATE KEY")?;
    let key =
        p256::SecretKey::from_pkcs8_pem(key_block).map_err(|_| "invalid P-256 private key")?;
    let certificate_bytes = fs::read(cert_path).map_err(|_| "cannot read certificate")?;
    let chain =
        SigningKey::cert_chain_from_bytes(&certificate_bytes).map_err(|_| "invalid certificate")?;
    if chain.len() < 2 {
        return Ok(false);
    }
    let leaf = chain.first().ok_or("certificate is empty")?;
    let public_key = certificate_public_key(leaf)?;
    Ok(key.public_key() == public_key)
}

/// 1 means the key matches the certificate leaf; 0 means it does not;
/// -1 means the material could not be parsed. No key bytes leave the module.
#[no_mangle]
pub extern "C" fn qingqi_key_matches_certificate(
    private_key: *const c_char,
    certificate: *const c_char,
) -> i32 {
    match panic::catch_unwind(|| key_matches_certificate(private_key, certificate)) {
        Ok(Ok(true)) => 1,
        Ok(Ok(false)) => 0,
        _ => -1,
    }
}

fn inspect_profile(path_ptr: *const c_char) -> Result<Vec<u8>, String> {
    let path = path(path_ptr)?;
    let bytes = fs::read(path).map_err(|_| "cannot read signed profile")?;
    if bytes.is_empty() || bytes.len() > 2 * 1024 * 1024 {
        return Err("signed profile size is invalid".into());
    }
    let verified = ProfileVerifier::verify(&bytes)
        .map_err(|error| format!("signed profile verification: {error}"))?;
    std::str::from_utf8(&verified.content).map_err(|_| "signed profile content is not UTF-8")?;
    Ok(verified.content)
}

/// Returns the cryptographically verified profile JSON. Callers must still
/// validate bundle, UDID, ACL and validity fields for their install job.
#[no_mangle]
pub extern "C" fn qingqi_read_signed_profile(
    profile_path: *const c_char,
    output: *mut u8,
    output_capacity: usize,
    output_length: *mut usize,
    error_buffer: *mut c_char,
    error_capacity: usize,
) -> i32 {
    match panic::catch_unwind(|| inspect_profile(profile_path)) {
        Ok(Ok(content))
            if !output.is_null()
                && !output_length.is_null()
                && content.len() <= output_capacity =>
        {
            unsafe {
                std::ptr::copy_nonoverlapping(content.as_ptr(), output, content.len());
                *output_length = content.len();
            }
            write_error(error_buffer, error_capacity, "");
            0
        }
        Ok(Ok(_)) => {
            write_error(
                error_buffer,
                error_capacity,
                "verified profile is too large",
            );
            1
        }
        Ok(Err(error)) => {
            write_error(error_buffer, error_capacity, &error);
            1
        }
        Err(_) => {
            write_error(
                error_buffer,
                error_capacity,
                "profile verifier stopped unexpectedly",
            );
            2
        }
    }
}

fn profile_matches_certificate(
    profile_path: *const c_char,
    certificate_path: *const c_char,
) -> Result<bool, String> {
    let content = inspect_profile(profile_path)?;
    let json: serde_json::Value =
        serde_json::from_slice(&content).map_err(|_| "verified profile is not JSON")?;
    if json.get("type").and_then(|value| value.as_str()) != Some("debug") {
        return Ok(false);
    }
    let embedded = json
        .get("bundle-info")
        .and_then(|value| value.get("development-certificate"))
        .and_then(|value| value.as_str())
        .ok_or("profile certificate is missing")?;
    let profile_chain = SigningKey::cert_chain_from_bytes(embedded.as_bytes())
        .map_err(|_| "profile certificate is invalid")?;
    let local_path = path(certificate_path)?;
    let local = fs::read(local_path).map_err(|_| "cannot read local certificate")?;
    let local_chain =
        SigningKey::cert_chain_from_bytes(&local).map_err(|_| "local certificate is invalid")?;
    if local_chain.len() < 2 {
        return Ok(false);
    }
    let profile_leaf = profile_chain
        .first()
        .ok_or("profile certificate is empty")?;
    let local_leaf = local_chain.first().ok_or("local certificate is empty")?;
    Ok(certificate_public_key(profile_leaf)? == certificate_public_key(local_leaf)?)
}

fn verify_hap_file(file_path: &Path) -> Result<(), String> {
    let file = fs::File::open(file_path).map_err(|_| "cannot open signed HAP")?;
    let mapped = unsafe { MmapOptions::new().map(&file) }.map_err(|_| "cannot map signed HAP")?;
    ApplicationVerifier::new(&mapped)
        .verify(InputFormat::Zip)
        .map_err(|error| format!("signed HAP verification: {error}"))?;
    Ok(())
}

#[no_mangle]
pub extern "C" fn qingqi_verify_hap(
    file_path: *const c_char,
    error_buffer: *mut c_char,
    error_capacity: usize,
) -> i32 {
    match panic::catch_unwind(|| {
        let path = path(file_path)?;
        verify_hap_file(Path::new(&path))
    }) {
        Ok(Ok(())) => {
            write_error(error_buffer, error_capacity, "");
            0
        }
        Ok(Err(error)) => {
            write_error(error_buffer, error_capacity, &error);
            1
        }
        Err(_) => {
            write_error(
                error_buffer,
                error_capacity,
                "verifier stopped unexpectedly",
            );
            2
        }
    }
}

/// 1 means a verified debug Profile embeds the same app certificate as the
/// existing AGC certificate chain; 0 means different; -1 means invalid.
#[no_mangle]
pub extern "C" fn qingqi_profile_matches_certificate(
    profile_path: *const c_char,
    certificate_path: *const c_char,
) -> i32 {
    match panic::catch_unwind(|| profile_matches_certificate(profile_path, certificate_path)) {
        Ok(Ok(true)) => 1,
        Ok(Ok(false)) => 0,
        _ => -1,
    }
}

fn sign(
    input: *const c_char,
    output: *const c_char,
    private_key: *const c_char,
    certificates: *const c_char,
    profile: *const c_char,
) -> Result<(), String> {
    let input = path(input)?;
    let output = path(output)?;
    let private_key = path(private_key)?;
    let certificates = path(certificates)?;
    let profile = path(profile)?;
    if input == output
        || (Path::new(&output).exists()
            && fs::canonicalize(&input).ok() == fs::canonicalize(&output).ok())
    {
        return Err("input and output HAP paths must differ".into());
    }
    let key_pem =
        Zeroizing::new(fs::read_to_string(private_key).map_err(|_| "cannot read private key")?);
    let chain_pem = fs::read(certificates).map_err(|_| "cannot read certificate chain")?;
    let profile_data = fs::read(profile).map_err(|_| "cannot read signed profile")?;
    let chain = SigningKey::cert_chain_from_bytes(&chain_pem)
        .map_err(|error| format!("certificate chain: {error}"))?;
    // The SDK verifier accepts a leaf-only CMS, but a 6.1 device rejected it
    // with 9568257. AGC's downloaded certificate contains the issuer chain.
    if chain.len() < 2 {
        return Err("certificate chain is incomplete".into());
    }
    let key_block = first_pem_block(&key_pem, "PRIVATE KEY")?;
    let parsed =
        p256::SecretKey::from_pkcs8_pem(key_block).map_err(|_| "invalid P-256 private key")?;
    let leaf = chain.first().ok_or("certificate chain is empty")?;
    let certificate_key = certificate_public_key(leaf)?;
    if parsed.public_key() != certificate_key {
        return Err("private key does not match certificate".into());
    }
    let private_der = parsed
        .to_pkcs8_der()
        .map_err(|_| "cannot encode P-256 private key")?;
    let material = SigningMaterial::from_der(
        private_der.as_bytes().to_vec(),
        chain,
        profile_data,
        SigningAlgorithm::EcdsaSha256,
    )
    .map_err(|error| format!("signing material: {error}"))?;
    let signer = HapSigner::new(
        material,
        SignOptions {
            compatible_version: 24,
            code_signing: true,
        },
    );
    let destination = Path::new(&output);
    let pending = PendingOutput::beside(destination)?;
    signer
        .sign_file(Path::new(&input), &pending.0)
        .map_err(|error| format!("HAP signing: {error}"))?;
    verify_hap_file(&pending.0)?;
    let signed = fs::File::open(&pending.0).map_err(|_| "cannot reopen signed HAP")?;
    signed.sync_all().map_err(|_| "cannot sync signed HAP")?;
    fs::rename(&pending.0, destination).map_err(|_| "cannot commit signed HAP")?;
    Ok(())
}

fn write_error(buffer: *mut c_char, capacity: usize, message: &str) {
    if buffer.is_null() || capacity == 0 {
        return;
    }
    let bytes = message.as_bytes();
    let len = bytes.len().min(capacity - 1);
    unsafe {
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), buffer.cast(), len);
        *buffer.add(len) = 0;
    }
}

/// Returns 0 only after cryptographic verification of the produced HAP.
/// Errors are copied into a caller-owned, NUL-terminated buffer.
#[no_mangle]
pub extern "C" fn qingqi_sign_hap(
    input: *const c_char,
    output: *const c_char,
    private_key: *const c_char,
    certificates: *const c_char,
    profile: *const c_char,
    error_buffer: *mut c_char,
    error_capacity: usize,
) -> i32 {
    match panic::catch_unwind(|| sign(input, output, private_key, certificates, profile)) {
        Ok(Ok(())) => {
            write_error(error_buffer, error_capacity, "");
            0
        }
        Ok(Err(error)) => {
            write_error(error_buffer, error_capacity, &error);
            1
        }
        Err(_) => {
            write_error(error_buffer, error_capacity, "signer stopped unexpectedly");
            2
        }
    }
}

/// Run only the HDC operations the installer needs. The Rust host server and
/// signer share this static library; HDC keys stay in the app's sandbox.
/// Bundle names arrive from the client and end up in an HDC argv, so they are
/// restricted to the shape HarmonyOS itself allows.
fn validate_bundle_name(name: &str) -> Result<(), String> {
    if !name.contains('.') || name.len() > 255 ||
        !name.bytes().all(|byte| byte.is_ascii_alphanumeric() ||
            byte == b'.' || byte == b'_') {
        return Err("invalid bundle name".into());
    }
    Ok(())
}

#[no_mangle]
pub extern "C" fn qingqi_hdc_command(
    key_root: *const c_char,
    port: u16,
    operation: u32,
    parameter: *const c_char,
    output: *mut u8,
    output_capacity: usize,
    output_length: *mut usize,
    error_buffer: *mut c_char,
    error_capacity: usize,
) -> i32 {
    let result = panic::catch_unwind(|| -> Result<String, String> {
        let root = path(key_root)?;
        let argument = if parameter.is_null() { String::new() } else { path(parameter)? };
        let args = match operation {
            0 => vec!["list".into(), "targets".into()],
            1 => {
                if !argument.starts_with("127.0.0.1:") &&
                    !argument.starts_with("localhost:") {
                    return Err("HDC target must be this device".into());
                }
                let port_text = argument.rsplit_once(':').map(|(_, port)| port)
                    .ok_or("HDC target has no port")?;
                let target_port: u16 = port_text.parse().map_err(|_| "invalid HDC target port")?;
                if target_port < 1024 { return Err("invalid HDC target port".into()); }
                vec!["tconn".into(), argument]
            }
            2 => vec!["shell".into(), "bm".into(), "get".into(), "--udid".into()],
            3 => {
                validate_bundle_name(&argument)?;
                vec!["shell".into(), "bm".into(), "dump".into(), "-n".into(), argument]
            }
            4 => {
                if !argument.starts_with(&format!("{root}/")) || !argument.ends_with(".hap") ||
                    argument.contains('"') || argument.contains('\n') {
                    return Err("HAP path is outside the application sandbox".into());
                }
                vec!["install".into(), "-r".into(), argument]
            }
            // 只查是否安装，不做任何改动；用于确认记录是否已经失效。
            5 => {
                validate_bundle_name(&argument)?;
                vec!["shell".into(), "bm".into(), "dump".into(), "-n".into(), argument]
            }
            _ => return Err("unsupported HDC operation".into()),
        };
        qingqi_hdc_transport::start(Path::new(&root), port)
            .map_err(|error| format!("HDC server: {error}"))?;
        qingqi_hdc_transport::command(port, &args,
            Duration::from_secs(if operation == 4 { 300 } else if operation == 1 { 90 } else { 30 }))
            .map_err(|error| format!("HDC command: {error}"))
    });
    let text = match result {
        Ok(Ok(text)) => text,
        Ok(Err(error)) => { write_error(error_buffer, error_capacity, &error); return 1; }
        Err(_) => {
            write_error(error_buffer, error_capacity, "HDC transport stopped unexpectedly");
            return 2;
        }
    };
    if output.is_null() || output_length.is_null() || text.len() > output_capacity {
        write_error(error_buffer, error_capacity, "HDC output exceeds buffer");
        return 1;
    }
    unsafe {
        std::ptr::copy_nonoverlapping(text.as_ptr(), output, text.len());
        *output_length = text.len();
    }
    write_error(error_buffer, error_capacity, "");
    0
}

#[cfg(test)]
mod tests {
    use super::PendingOutput;
    use std::fs;

    #[test]
    fn abandoned_signature_preserves_previous_output() {
        let dir = std::env::temp_dir().join(format!("qingqi-sign-atomic-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let destination = dir.join("app.hap");
        fs::write(&destination, b"previous verified HAP").unwrap();
        let temporary = {
            let pending = PendingOutput::beside(&destination).unwrap();
            fs::write(&pending.0, b"incomplete HAP").unwrap();
            pending.0.clone()
        };
        assert_eq!(fs::read(&destination).unwrap(), b"previous verified HAP");
        assert!(!temporary.exists());
        fs::remove_file(destination).unwrap();
        fs::remove_dir(dir).unwrap();
    }
}
