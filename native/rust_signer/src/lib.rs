//! In-process HAP signing bridge. No key, profile or certificate is embedded
//! in the application; callers supply paths inside their own sandbox.

use std::ffi::{c_char, CStr};
use std::io::{Read, Write};
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::{fs, panic};
use std::str::FromStr;
use std::time::Duration;

use hapsigner::{
    ApplicationVerification, ApplicationVerifier, HapSigner, InputFormat, ProfileVerifier, SignOptions, SigningAlgorithm,
    SigningKey, SigningMaterial,
};
use memmap2::MmapOptions;
use p256::pkcs8::{DecodePrivateKey, DecodePublicKey, EncodePrivateKey};
use p256::ecdsa::DerSignature;
use sha2::{Digest, Sha256};
use x509_cert::builder::{Builder, RequestBuilder};
use x509_cert::der::{pem::LineEnding, Decode, Encode, EncodePem};
use x509_cert::{name::Name, Certificate};
use zeroize::Zeroizing;
use zip::{ZipArchive, ZipWriter};

const QUIETSTART_BUNDLE: &str = "com.tonghongxiang.quietstart";
const WORKER_PATH: &str = "resources/rawfile/quietstart-worker.hap";
const WORKER_MANIFEST_PATH: &str = "resources/rawfile/quietstart-worker.json";
// The receiving QuietStart app itself rejects a larger embedded worker.
const WORKER_LIMIT: u64 = 16 * 1024 * 1024;
const SELF_UPDATE_HAP: &str = "/data/local/tmp/qingqi-self-update.hap";
const SELF_UPDATE_SCRIPT: &str = "/data/local/tmp/qingqi-self-update.sh";
const SELF_UPDATE_LOG: &str = "/data/local/tmp/qingqi-self-update.log";

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

#[derive(PartialEq, Eq)]
enum EcPublicKey {
    P256(p256::PublicKey),
    P384(p384::PublicKey),
}

enum EcPrivateKey {
    P256(p256::SecretKey),
    P384(p384::SecretKey),
}

impl EcPrivateKey {
    fn public_key(&self) -> EcPublicKey {
        match self {
            Self::P256(key) => EcPublicKey::P256(key.public_key()),
            Self::P384(key) => EcPublicKey::P384(key.public_key()),
        }
    }

    fn signing_algorithm(&self) -> SigningAlgorithm {
        match self {
            Self::P256(_) => SigningAlgorithm::EcdsaSha256,
            Self::P384(_) => SigningAlgorithm::EcdsaSha384,
        }
    }

    fn to_pkcs8_der(&self) -> Result<Vec<u8>, String> {
        match self {
            Self::P256(key) => key.to_pkcs8_der().map(|der| der.as_bytes().to_vec()),
            Self::P384(key) => key.to_pkcs8_der().map(|der| der.as_bytes().to_vec()),
        }
        .map_err(|_| "cannot encode EC private key".into())
    }
}

fn parse_ec_private_key(pem: &str) -> Result<EcPrivateKey, String> {
    let block = first_pem_block(pem, "PRIVATE KEY")?;
    if let Ok(key) = p256::SecretKey::from_pkcs8_pem(block) {
        return Ok(EcPrivateKey::P256(key));
    }
    p384::SecretKey::from_pkcs8_pem(block)
        .map(EcPrivateKey::P384)
        .map_err(|_| "invalid P-256/P-384 private key".into())
}

/// A valid certificate may use another curve or RSA. Such a certificate
/// cannot match our EC key, but must not abort scanning the account's list.
fn certificate_public_key(der: &[u8]) -> Result<Option<EcPublicKey>, String> {
    let cert = Certificate::from_der(der).map_err(|_| "invalid certificate DER")?;
    let spki = cert
        .tbs_certificate
        .subject_public_key_info
        .to_der()
        .map_err(|_| "invalid certificate public key")?;
    if let Ok(key) = p256::PublicKey::from_public_key_der(&spki) {
        return Ok(Some(EcPublicKey::P256(key)));
    }
    if let Ok(key) = p384::PublicKey::from_public_key_der(&spki) {
        return Ok(Some(EcPublicKey::P384(key)));
    }
    Ok(None)
}

fn key_matches_certificate(
    private_key: *const c_char,
    certificate: *const c_char,
) -> Result<bool, String> {
    let key_path = path(private_key)?;
    let cert_path = path(certificate)?;
    let key_pem =
        Zeroizing::new(fs::read_to_string(&key_path).map_err(|error| format!("cannot read private key {key_path}: {error}"))?);
    let key = parse_ec_private_key(&key_pem)?;
    let certificate_bytes = fs::read(&cert_path).map_err(|error| format!("cannot read certificate {cert_path}: {error}"))?;
    let chain =
        SigningKey::cert_chain_from_bytes(&certificate_bytes).map_err(|_| "invalid certificate")?;
    if chain.len() < 2 {
        return Ok(false);
    }
    let leaf = chain.first().ok_or("certificate is empty")?;
    let public_key = certificate_public_key(leaf)?;
    Ok(Some(key.public_key()) == public_key)
}

#[no_mangle]
pub extern "C" fn qingqi_certificate_fingerprint(
    certificate: *const c_char,
    output: *mut u8,
    output_capacity: usize,
    error_buffer: *mut c_char,
    error_capacity: usize,
) -> i32 {
    let result = panic::catch_unwind(|| -> Result<String, String> {
        let cert_path = path(certificate)?;
        let bytes = fs::read(cert_path).map_err(|error| format!("cannot read certificate: {error}"))?;
        let chain = SigningKey::cert_chain_from_bytes(&bytes)
            .map_err(|_| "invalid certificate".to_string())?;
        let leaf = chain.first().ok_or("certificate is empty")?;
        Ok(format!("{:x}", Sha256::digest(leaf)).to_uppercase())
    });
    match result {
        Ok(Ok(fingerprint)) if !output.is_null() && output_capacity >= 65 => {
            unsafe {
                std::ptr::copy_nonoverlapping(fingerprint.as_ptr(), output, 64);
                *output.add(64) = 0;
            }
            write_error(error_buffer, error_capacity, "");
            0
        }
        Ok(Ok(_)) => { write_error(error_buffer, error_capacity, "fingerprint buffer too small"); 1 }
        Ok(Err(error)) => { write_error(error_buffer, error_capacity, &error); 1 }
        Err(_) => { write_error(error_buffer, error_capacity, "certificate fingerprint failed"); 2 }
    }
}

/// 1 means the key matches the certificate leaf; 0 means it does not;
/// -1 means the material could not be parsed. No key bytes leave the module.
#[no_mangle]
pub extern "C" fn qingqi_key_matches_certificate(
    private_key: *const c_char,
    certificate: *const c_char,
    error_buffer: *mut c_char,
    error_capacity: usize,
) -> i32 {
    write_error(error_buffer, error_capacity, "");
    match panic::catch_unwind(|| key_matches_certificate(private_key, certificate)) {
        Ok(Ok(true)) => 1,
        Ok(Ok(false)) => 0,
        Ok(Err(error)) => {
            write_error(error_buffer, error_capacity, &error);
            -1
        }
        Err(_) => {
            write_error(error_buffer, error_capacity, "key verification stopped unexpectedly");
            -1
        }
    }
}

/// Build the PKCS#10 request from the same PKCS#8 key used for HAP signing.
/// The platform CSR API fails for freshly generated EC keys on HarmonyOS 6.1;
/// doing this in the existing Rust signer avoids a second key or AGC slot.
fn csr_from_private_key(private_key_pem: &str) -> Result<String, String> {
    let private_key = parse_ec_private_key(private_key_pem)?;
    // RFC4514 order is reverse of the slash-separated subject used by ArkTS.
    let subject = Name::from_str("CN=qingqi-installer,OU=Device,O=Qingqi,C=CN")
        .map_err(|_| "invalid CSR subject")?;
    let request = match private_key {
        EcPrivateKey::P256(key) => {
            let signer = p256::ecdsa::SigningKey::from(key);
            RequestBuilder::new(subject, &signer)
                .map_err(|_| "cannot prepare certificate request")?
                .build::<DerSignature>()
                .map_err(|_| "cannot sign certificate request")?
        }
        EcPrivateKey::P384(key) => {
            let signer = p384::ecdsa::SigningKey::from(key);
            RequestBuilder::new(subject, &signer)
                .map_err(|_| "cannot prepare certificate request")?
                .build::<p384::ecdsa::DerSignature>()
                .map_err(|_| "cannot sign certificate request")?
        }
    };
    request.to_pem(LineEnding::LF).map_err(|_| "cannot encode certificate request".into())
}

/// Returns a NUL-terminated-error status and a bounded PEM CSR. The private
/// key is supplied by the app process and never sent to a server here.
#[no_mangle]
pub extern "C" fn qingqi_generate_csr(
    private_key_pem: *const c_char,
    output: *mut u8,
    output_capacity: usize,
    output_length: *mut usize,
    error_buffer: *mut c_char,
    error_capacity: usize,
) -> i32 {
    let result = panic::catch_unwind(|| -> Result<String, String> {
        if private_key_pem.is_null() {
            return Err("missing private key".into());
        }
        let input = unsafe { CStr::from_ptr(private_key_pem) }
            .to_str().map_err(|_| "private key is not UTF-8")?;
        if input.len() > 4096 { return Err("private key is too long".into()); }
        csr_from_private_key(input)
    });
    let csr = match result {
        Ok(Ok(csr)) => csr,
        Ok(Err(error)) => { write_error(error_buffer, error_capacity, &error); return 1; }
        Err(_) => {
            write_error(error_buffer, error_capacity, "CSR generation stopped unexpectedly");
            return 2;
        }
    };
    if output.is_null() || output_length.is_null() || csr.len() > output_capacity {
        write_error(error_buffer, error_capacity, "CSR output exceeds buffer");
        return 1;
    }
    unsafe {
        std::ptr::copy_nonoverlapping(csr.as_ptr(), output, csr.len());
        *output_length = csr.len();
    }
    write_error(error_buffer, error_capacity, "");
    0
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
    let local_path = path(certificate_path)?;
    let local = fs::read(local_path).map_err(|_| "cannot read local certificate")?;
    let local_chain =
        SigningKey::cert_chain_from_bytes(&local).map_err(|_| "local certificate is invalid")?;
    Ok(chain_for_profile(&content, local_chain).is_ok())
}

fn debug_profile_certificate(content: &[u8]) -> Result<Vec<u8>, String> {
    let json: serde_json::Value = serde_json::from_slice(content)
        .map_err(|_| "verified profile is not JSON")?;
    if json.get("type").and_then(|value| value.as_str()) != Some("debug") {
        return Err("signing requires a debug device profile".into());
    }
    let pem = json.pointer("/bundle-info/development-certificate")
        .and_then(|value| value.as_str()).ok_or("profile certificate is missing")?;
    SigningKey::cert_chain_from_bytes(pem.as_bytes())
        .map_err(|_| "profile certificate is invalid".to_string())?
        .into_iter().next().ok_or("profile certificate is empty".into())
}

// A renewed AGC certificate can contain the same public key with different DER.
// The device requires the exact leaf declared in its signed Profile, not just
// the same key. Reuse that leaf and the downloaded issuer chain without changing
// the user's private key or occupying another AGC certificate slot.
fn chain_for_profile(content: &[u8], mut local_chain: Vec<Vec<u8>>)
    -> Result<Vec<Vec<u8>>, String> {
    if local_chain.len() < 2 { return Err("certificate chain is incomplete".into()); }
    let profile_leaf = debug_profile_certificate(content)?;
    let local_leaf = &local_chain[0];
    let key = certificate_public_key(&profile_leaf)?;
    if key.is_none() || key != certificate_public_key(local_leaf)? {
        return Err("signing certificate differs from AGC profile; refresh device authorization".into());
    }
    let profile_certificate = Certificate::from_der(&profile_leaf)
        .map_err(|_| "invalid profile certificate")?;
    let local_certificate = Certificate::from_der(local_leaf)
        .map_err(|_| "invalid local certificate")?;
    if profile_certificate.tbs_certificate.issuer != local_certificate.tbs_certificate.issuer {
        return Err("profile certificate issuer changed; refresh device authorization".into());
    }
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)
        .map_err(|_| "device clock is invalid")?;
    let validity = &profile_certificate.tbs_certificate.validity;
    if now < validity.not_before.to_unix_duration() || now >= validity.not_after.to_unix_duration() {
        return Err("profile signing certificate is expired or not yet valid".into());
    }
    local_chain[0] = profile_leaf;
    SigningKey::cert_chain_from_bytes(&local_chain.concat())
        .map_err(|error| format!("profile certificate chain: {error}"))
}

fn verify_profile_signer(hap: &ApplicationVerification) -> Result<(), String> {
    let Some(profile) = hap.profile.as_ref() else { return Ok(()); };
    let content = ProfileVerifier::verify(profile)
        .map_err(|error| format!("device profile verification: {error}"))?.content;
    let json: serde_json::Value = serde_json::from_slice(&content)
        .map_err(|_| "verified profile is not JSON")?;
    if json.get("type").and_then(|value| value.as_str()) == Some("debug") {
        let leaf = debug_profile_certificate(&content)?;
        let chain = SigningKey::cert_chain_from_bytes(&hap.certificates.concat())
            .map_err(|error| format!("HAP certificate chain: {error}"))?;
        if chain.first() != Some(&leaf) {
            return Err("HAP signer differs from the certificate declared in its device profile".into());
        }
    }
    Ok(())
}

fn verified_hap(file_path: &Path) -> Result<ApplicationVerification, String> {
    let file = fs::File::open(file_path).map_err(|_| "cannot open signed HAP")?;
    let mapped = unsafe { MmapOptions::new().map(&file) }.map_err(|_| "cannot map signed HAP")?;
    ApplicationVerifier::new(&mapped)
        .verify(InputFormat::Zip)
        .map_err(|error| format!("signed HAP verification: {error}"))
}

fn verify_hap_file(file_path: &Path) -> Result<(), String> {
    verified_hap(file_path).map(|_| ())
}

fn matching_layer_authorization(main: &ApplicationVerification,
    worker: &ApplicationVerification) -> Result<(), String> {
    let profile = main.profile.as_ref().filter(|bytes| !bytes.is_empty())
        .ok_or("QuietStart main HAP has no signed device profile")?;
    if worker.profile.as_ref() != Some(profile) {
        return Err("QuietStart worker device profile differs from main HAP; resign both modules".into());
    }
    ProfileVerifier::verify(profile)
        .map_err(|error| format!("QuietStart device profile verification: {error}"))?;
    let mut main_certificates = main.certificates.clone();
    let mut worker_certificates = worker.certificates.clone();
    main_certificates.sort();
    worker_certificates.sort();
    if main_certificates.is_empty() || main_certificates != worker_certificates {
        return Err("QuietStart worker signing certificate differs from main HAP; resign both modules".into());
    }
    Ok(())
}

// An outer signature cannot prove that an embedded HAP carries this device's
// authorization. Also apply this check to resumed jobs signed by older versions.
fn verify_installable_hap(file_path: &Path) -> Result<(), String> {
    let main = verified_hap(file_path)?;
    verify_profile_signer(&main)?;
    if let Some(worker) = quietstart_worker(file_path)? {
        let verified_worker = ApplicationVerifier::new(&worker.bytes)
            .verify(InputFormat::Zip)
            .map_err(|error| format!("QuietStart worker signature verification: {error}"))?;
        matching_layer_authorization(&main, &verified_worker)?;
        verify_profile_signer(&verified_worker)?;
    }
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
        verify_installable_hap(Path::new(&path))
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

struct QuietStartWorker {
    bytes: Vec<u8>,
    manifest: serde_json::Value,
    permissions: Vec<String>,
}

fn module_permissions(module: &serde_json::Value) -> Vec<String> {
    module.pointer("/module/requestPermissions").and_then(|value| value.as_array())
        .into_iter().flatten().filter_map(|row| row.get("name").and_then(|value| value.as_str()))
        .filter(|name| name.starts_with("ohos.permission.") &&
            name.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'.' || byte == b'_'))
        .map(str::to_owned).collect()
}

fn installation_permissions(input: &Path) -> Result<String, String> {
    let mut archive = ZipArchive::new(fs::File::open(input).map_err(|_| "cannot open source HAP")?)
        .map_err(|_| "source HAP is not a ZIP")?;
    let module: serde_json::Value = serde_json::from_slice(
        &zip_entry(&mut archive, "module.json", 256 * 1024)?)
        .map_err(|_| "source HAP module.json is invalid")?;
    let mut permissions = module_permissions(&module);
    if let Some(worker) = quietstart_worker(input)? {
        permissions.extend(worker.permissions);
    }
    permissions.sort();
    permissions.dedup();
    serde_json::to_string(&permissions).map_err(|_| "cannot encode HAP permissions".into())
}

#[no_mangle]
pub extern "C" fn qingqi_read_install_permissions(input: *const c_char,
    output: *mut u8, capacity: usize, length: *mut usize,
    error: *mut c_char, error_capacity: usize) -> i32 {
    match panic::catch_unwind(|| installation_permissions(Path::new(&path(input)?))) {
        Ok(Ok(json)) if !output.is_null() && !length.is_null() && json.len() <= capacity => {
            unsafe {
                std::ptr::copy_nonoverlapping(json.as_ptr(), output, json.len());
                *length = json.len();
            }
            write_error(error, error_capacity, "");
            0
        }
        Ok(Ok(_)) => { write_error(error, error_capacity, "HAP permissions exceed output capacity"); 1 }
        Ok(Err(detail)) => { write_error(error, error_capacity, &detail); 1 }
        Err(_) => { write_error(error, error_capacity, "HAP permission reader stopped unexpectedly"); 2 }
    }
}

fn zip_entry(archive: &mut ZipArchive<impl Read + std::io::Seek>,
    name: &str, limit: u64) -> Result<Vec<u8>, String> {
    let entry = archive.by_name(name)
        .map_err(|error| format!("{name} is missing: {error}"))?;
    if entry.size() > limit {
        return Err(format!("{name} exceeds the supported size"));
    }
    let mut bytes = Vec::with_capacity(entry.size() as usize);
    entry.take(limit + 1).read_to_end(&mut bytes)
        .map_err(|error| format!("cannot read {name}: {error}"))?;
    if bytes.len() as u64 > limit {
        return Err(format!("{name} exceeds the supported size"));
    }
    Ok(bytes)
}

/// QuietStart installs its embedded `entry_test` HAP after the outer app starts.
/// The outer and inner modules must therefore carry the same user's signature.
fn quietstart_worker(input: &Path) -> Result<Option<QuietStartWorker>, String> {
    let source = fs::File::open(input).map_err(|_| "cannot open source HAP")?;
    let mut archive = ZipArchive::new(source)
        .map_err(|error| format!("cannot read source HAP ZIP: {error}"))?;
    if archive.file_names().filter(|path| *path == "module.json").count() != 1 {
        return Err("source HAP must contain exactly one module.json".into());
    }
    let main: serde_json::Value = serde_json::from_slice(
        &zip_entry(&mut archive, "module.json", 256 * 1024)?)
        .map_err(|_| "source HAP module.json is invalid")?;
    if main.pointer("/app/bundleName").and_then(|v| v.as_str()) != Some(QUIETSTART_BUNDLE) {
        return Ok(None);
    }
    let version = main.pointer("/app/versionCode").and_then(|v| v.as_u64())
        .ok_or("QuietStart main module has no version code")?;
    if main.pointer("/module/name").and_then(|v| v.as_str()) != Some("entry") {
        return Err("QuietStart main module name is invalid".into());
    }
    for name in [WORKER_PATH, WORKER_MANIFEST_PATH] {
        if archive.file_names().filter(|path| *path == name).count() != 1 {
            return Err(format!("QuietStart package must contain exactly one {name}"));
        }
    }
    let bytes = zip_entry(&mut archive, WORKER_PATH, WORKER_LIMIT)?;
    let manifest: serde_json::Value = serde_json::from_slice(
        &zip_entry(&mut archive, WORKER_MANIFEST_PATH, 64 * 1024)?)
        .map_err(|_| "QuietStart worker manifest is invalid")?;
    if manifest.get("bundleName").and_then(|v| v.as_str()) != Some(QUIETSTART_BUNDLE)
        || manifest.get("moduleName").and_then(|v| v.as_str()) != Some("entry_test")
        || manifest.get("versionCode").and_then(|v| v.as_u64()) != Some(version)
        || manifest.get("size").and_then(|v| v.as_u64()) != Some(bytes.len() as u64)
        || manifest.get("sha256").and_then(|v| v.as_str())
            != Some(&format!("{:x}", Sha256::digest(&bytes))) {
        return Err("QuietStart worker manifest does not match its HAP".into());
    }
    let mut inner = ZipArchive::new(std::io::Cursor::new(bytes.as_slice()))
        .map_err(|_| "QuietStart worker HAP is not a ZIP")?;
    if inner.file_names().filter(|path| *path == "module.json").count() != 1 {
        return Err("QuietStart worker must contain exactly one module.json".into());
    }
    let worker: serde_json::Value = serde_json::from_slice(
        &zip_entry(&mut inner, "module.json", 256 * 1024)?)
        .map_err(|_| "QuietStart worker module.json is invalid")?;
    if worker.pointer("/app/bundleName").and_then(|v| v.as_str()) != Some(QUIETSTART_BUNDLE)
        || worker.pointer("/app/versionCode").and_then(|v| v.as_u64()) != Some(version)
        || worker.pointer("/module/name").and_then(|v| v.as_str()) != Some("entry_test") {
        return Err("QuietStart main and worker identities differ".into());
    }
    drop(inner);
    Ok(Some(QuietStartWorker { bytes, manifest, permissions: module_permissions(&worker) }))
}

fn repack_quietstart(input: &Path, output: &Path,
    signed_worker: &[u8], manifest: &[u8]) -> Result<(), String> {
    let source = fs::File::open(input).map_err(|_| "cannot reopen QuietStart HAP")?;
    let mut archive = ZipArchive::new(source)
        .map_err(|_| "cannot reopen QuietStart HAP ZIP")?;
    let file = fs::File::create(output).map_err(|_| "cannot create layered HAP")?;
    let mut writer = ZipWriter::new(file);
    for index in 0..archive.len() {
        let entry = archive.by_index(index)
            .map_err(|error| format!("cannot read HAP entry: {error}"))?;
        let replacement = match entry.name() {
            WORKER_PATH => Some(signed_worker),
            WORKER_MANIFEST_PATH => Some(manifest),
            _ => None,
        };
        if let Some(bytes) = replacement {
            let name = entry.name().to_owned();
            writer.start_file(name, entry.options())
                .map_err(|error| format!("cannot replace HAP entry: {error}"))?;
            writer.write_all(bytes)
                .map_err(|error| format!("cannot write HAP entry: {error}"))?;
        } else {
            writer.raw_copy_file(entry)
                .map_err(|error| format!("cannot copy HAP entry: {error}"))?;
        }
    }
    writer.finish().map_err(|error| format!("cannot finish layered HAP: {error}"))?
        .sync_all().map_err(|_| "cannot sync layered HAP")?;
    Ok(())
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
    let content = ProfileVerifier::verify(&profile_data)
        .map_err(|error| format!("signed profile verification: {error}"))?.content;
    let chain = chain_for_profile(&content, chain)?;
    // The SDK verifier accepts a leaf-only CMS, but a 6.1 device rejected it
    // with 9568257. AGC's downloaded certificate contains the issuer chain.
    if chain.len() < 2 {
        return Err("certificate chain is incomplete".into());
    }
    let parsed = parse_ec_private_key(&key_pem)?;
    let leaf = chain.first().ok_or("certificate chain is empty")?;
    let certificate_key = certificate_public_key(leaf)?;
    if Some(parsed.public_key()) != certificate_key {
        return Err("private key does not match certificate".into());
    }
    let algorithm = parsed.signing_algorithm();
    let private_der = parsed.to_pkcs8_der()?;
    let material = SigningMaterial::from_der(
        private_der,
        chain,
        profile_data,
        algorithm,
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
    let mut layered_input = None;
    if let Some(mut worker) = quietstart_worker(Path::new(&input))? {
        let worker_input = PendingOutput::beside(destination)?;
        let worker_output = PendingOutput::beside(destination)?;
        fs::write(&worker_input.0, &worker.bytes)
            .map_err(|_| "cannot stage QuietStart worker")?;
        signer.sign_file(&worker_input.0, &worker_output.0)
            .map_err(|error| format!("QuietStart worker signing: {error}"))?;
        verify_hap_file(&worker_output.0)?;
        let signed_len = fs::metadata(&worker_output.0)
            .map_err(|_| "cannot inspect signed QuietStart worker")?.len();
        if signed_len > WORKER_LIMIT {
            return Err("signed QuietStart worker exceeds the app's 16 MB limit".into());
        }
        worker.bytes = fs::read(&worker_output.0)
            .map_err(|_| "cannot read signed QuietStart worker")?;
        worker.manifest["size"] = serde_json::Value::from(worker.bytes.len());
        worker.manifest["sha256"] = serde_json::Value::from(
            format!("{:x}", Sha256::digest(&worker.bytes)));
        let mut manifest = serde_json::to_vec_pretty(&worker.manifest)
            .map_err(|_| "cannot encode QuietStart worker manifest")?;
        manifest.push(b'\n');
        let main_input = PendingOutput::beside(destination)?;
        repack_quietstart(Path::new(&input), &main_input.0, &worker.bytes, &manifest)?;
        layered_input = Some(main_input);
    }
    let source = layered_input.as_ref().map_or(Path::new(&input), |temp| temp.0.as_path());
    signer
        .sign_file(source, &pending.0)
        .map_err(|error| format!("HAP signing: {error}"))?;
    verify_installable_hap(&pending.0)?;
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

/// Drop every HDC device link, releasing the device's wireless debugging endpoint.
///
/// The protocol has no "disconnect" verb, so this drops the transport instead.
/// The loopback server keeps running; the next command reconnects by itself.
/// Returns the number of links dropped, or -1 on failure.
#[no_mangle]
pub extern "C" fn qingqi_hdc_disconnect(
    error_buffer: *mut c_char,
    error_capacity: usize,
) -> i32 {
    match panic::catch_unwind(|| qingqi_hdc_transport::disconnect()) {
        Ok(Ok(dropped)) => {
            write_error(error_buffer, error_capacity, "");
            dropped as i32
        }
        Ok(Err(error)) => {
            write_error(error_buffer, error_capacity, &format!("HDC disconnect: {error}"));
            -1
        }
        Err(_) => {
            write_error(error_buffer, error_capacity, "HDC disconnect stopped unexpectedly");
            -1
        }
    }
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
            // 一次列出全部已安装包名。逐个 `bm dump -n` 是「一个包一次设备往返」，
            // 目录里有多少应用就要多少次；这里一次问完，刷新耗时不再随应用数量
            // 线性增长（实测应用一多，逐个查询会让刷新慢到十几秒）。
            6 => vec!["shell".into(), "bm".into(), "dump".into(), "-a".into()],
            7 => {
                validate_bundle_name(&argument)?;
                vec!["uninstall".into(), argument]
            }
            8 => {
                let sandbox = fs::canonicalize(&root).map_err(|error| error.to_string())?;
                let package = fs::canonicalize(&argument).map_err(|error| error.to_string())?;
                if !package.starts_with(&sandbox) || !argument.ends_with(".hap") ||
                    argument.contains('"') || argument.contains('\n') || argument.contains(' ') {
                    return Err("self-update HAP path is invalid".into());
                }
                vec!["file".into(), "send".into(), argument, SELF_UPDATE_HAP.into()]
            }
            9 => vec!["shell".into(), "sh".into(), "-c".into(),
                format!("'nohup sh {SELF_UPDATE_SCRIPT} >{SELF_UPDATE_LOG} 2>&1 </dev/null &'")],
            _ => return Err("unsupported HDC operation".into()),
        };
        // start() 返回实际监听端口：首选端口被别的程序占用时它会换一个空闲的
        let actual_port = qingqi_hdc_transport::start(Path::new(&root), port)
            .map_err(|error| format!("HDC server: {error}"))?;
        if operation == 8 {
            let mut local = fs::File::open(&args[2])
                .map_err(|error| format!("cannot read self-update HAP: {error}"))?;
            let mut digest = Sha256::new();
            let mut block = [0u8; 64 * 1024];
            loop {
                let count = local.read(&mut block).map_err(|error| error.to_string())?;
                if count == 0 { break; }
                digest.update(&block[..count]);
            }
            let expected = format!("{:x}", digest.finalize());
            let send = |args: &[String]| -> Result<String, String> {
                let output = qingqi_hdc_transport::command(actual_port, args,
                    Duration::from_secs(300)).map_err(|error| format!("HDC transfer: {error}"))?;
                if output.contains("[Fail]") || !output.contains("FileTransfer finish") {
                    return Err(format!("HDC file transfer did not finish: {output}"));
                }
                Ok(output)
            };
            send(&args)?;
            let script = format!(
                "#!/system/bin/sh\n\
                 sleep 2\n\
                 bm uninstall -n com.tonghongxiang.hapstore\n\
                 bm install -p {SELF_UPDATE_HAP}\n\
                 status=$?\n\
                 if [ $status -eq 0 ]; then rm -f {SELF_UPDATE_HAP} {SELF_UPDATE_SCRIPT}; fi\n\
                 exit $status\n");
            let local_script = format!("{root}/qingqi-self-update.sh");
            fs::write(&local_script, &script).map_err(|error| error.to_string())?;
            send(&["file".into(), "send".into(), local_script, SELF_UPDATE_SCRIPT.into()])?;
            let script_checksum = qingqi_hdc_transport::command(actual_port,
                &["shell".into(), "sha256sum".into(), SELF_UPDATE_SCRIPT.into()],
                Duration::from_secs(15)).map_err(|error| format!("remote script checksum: {error}"))?;
            let script_expected = format!("{:x}", Sha256::digest(script.as_bytes()));
            if !script_checksum.to_ascii_lowercase().contains(&script_expected) {
                return Err("staged self-update script checksum does not match".into());
            }
            let checksum = qingqi_hdc_transport::command(actual_port,
                &["shell".into(), "sha256sum".into(), SELF_UPDATE_HAP.into()],
                Duration::from_secs(45)).map_err(|error| format!("remote checksum: {error}"))?;
            if !checksum.to_ascii_lowercase().contains(&expected) {
                return Err("staged self-update HAP checksum does not match".into());
            }
            return Ok("self-update staged and verified".into());
        }
        qingqi_hdc_transport::command(actual_port, &args,
            Duration::from_secs(if operation == 4 { 300 }
                else if operation == 7 { 90 }
                else if operation == 9 { 15 }
                else if operation == 1 { 15 }
                else if operation == 2 { 8 }
                else { 30 }))
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
    use super::{quietstart_worker, repack_quietstart, PendingOutput, NEXT_TEMP,
        WORKER_MANIFEST_PATH, WORKER_PATH};
    use sha2::{Digest, Sha256};
    use std::{fs, io::{Cursor, Write}, sync::atomic::Ordering};
    use zip::{write::SimpleFileOptions, ZipArchive, ZipWriter};

    fn sample_zip(entries: &[(&str, &[u8])]) -> Vec<u8> {
        let mut writer = ZipWriter::new(Cursor::new(Vec::new()));
        for (name, content) in entries {
            writer.start_file(*name, SimpleFileOptions::default()).unwrap();
            writer.write_all(content).unwrap();
        }
        writer.finish().unwrap().into_inner()
    }

    #[test]
    fn quietstart_layered_repack_replaces_only_worker_and_manifest() {
        let dir = std::env::temp_dir().join(format!("qingqi-layered-{}-{}",
            std::process::id(), NEXT_TEMP.fetch_add(1, Ordering::Relaxed)));
        fs::create_dir_all(&dir).unwrap();
        let input = dir.join("input.hap");
        let output = dir.join("output.hap");
        let inner_manifest = br#"{"app":{"bundleName":"com.tonghongxiang.quietstart","versionCode":120000},"module":{"name":"entry_test","requestPermissions":[{"name":"ohos.permission.KEEP_BACKGROUND_RUNNING_SYSTEM"},{"name":"ohos.permission.INTERNET"}]}}"#;
        let outer_manifest = br#"{"app":{"bundleName":"com.tonghongxiang.quietstart","versionCode":120000},"module":{"name":"entry","requestPermissions":[{"name":"ohos.permission.INTERNET"}]}}"#;
        let worker = sample_zip(&[("module.json", inner_manifest), ("payload.txt", b"original")]);
        let manifest = serde_json::json!({
            "bundleName":"com.tonghongxiang.quietstart", "moduleName":"entry_test",
            "versionCode":120000, "size":worker.len(),
            "sha256":format!("{:x}", Sha256::digest(&worker))
        });
        let manifest_bytes = serde_json::to_vec(&manifest).unwrap();
        fs::write(&input, sample_zip(&[("module.json", outer_manifest),
            (WORKER_PATH, &worker), (WORKER_MANIFEST_PATH, &manifest_bytes),
            ("ordinary.txt", b"must remain unchanged")])).unwrap();
        let extracted = quietstart_worker(&input).unwrap().unwrap();
        assert_eq!(extracted.bytes, worker);
        assert_eq!(super::installation_permissions(&input).unwrap(),
            r#"["ohos.permission.INTERNET","ohos.permission.KEEP_BACKGROUND_RUNNING_SYSTEM"]"#);

        let replacement = sample_zip(&[("module.json", inner_manifest),
            ("payload.txt", b"signed worker")]);
        let new_manifest = serde_json::json!({
            "bundleName":"com.tonghongxiang.quietstart", "moduleName":"entry_test",
            "versionCode":120000, "size":replacement.len(),
            "sha256":format!("{:x}", Sha256::digest(&replacement))
        });
        repack_quietstart(&input, &output, &replacement,
            &serde_json::to_vec(&new_manifest).unwrap()).unwrap();
        let mut archive = ZipArchive::new(fs::File::open(&output).unwrap()).unwrap();
        let actual = super::zip_entry(&mut archive, WORKER_PATH, super::WORKER_LIMIT).unwrap();
        assert_eq!(actual, replacement);
        assert_eq!(super::zip_entry(&mut archive, WORKER_MANIFEST_PATH, 64 * 1024).unwrap(),
            serde_json::to_vec(&new_manifest).unwrap());
        assert_eq!(super::zip_entry(&mut archive, "ordinary.txt", 1024).unwrap(),
            b"must remain unchanged");
        drop(archive);
        assert!(quietstart_worker(&output).is_ok());
        fs::remove_dir_all(dir).unwrap();
    }

    fn synthetic_chain(leaf_is_p384: bool) -> (String, String) {
        synthetic_chain_with_serial(leaf_is_p384, 2)
    }

    fn synthetic_chain_with_serial(leaf_is_p384: bool, serial: u32) -> (String, String) {
        use p256::pkcs8::{EncodePrivateKey, EncodePublicKey};
        use x509_cert::builder::{Builder, CertificateBuilder, Profile};
        use x509_cert::der::{pem::LineEnding, EncodePem};
        use x509_cert::name::Name;
        use x509_cert::serial_number::SerialNumber;
        use x509_cert::spki::SubjectPublicKeyInfoOwned;
        use x509_cert::time::Validity;
        use std::{str::FromStr, time::Duration};

        let mut root_scalar = [0u8; 48];
        root_scalar[47] = 7;
        let root_key = p384::SecretKey::from_slice(&root_scalar).unwrap();
        let root_signer = p384::ecdsa::SigningKey::from(root_key);
        let root_name = Name::from_str("CN=Test Root,O=Qingqi,C=CN").unwrap();
        let root_spki = root_signer.verifying_key().to_public_key_der().unwrap();
        let root_public = SubjectPublicKeyInfoOwned::try_from(root_spki.as_bytes()).unwrap();
        let validity = Validity::from_now(Duration::from_secs(3600)).unwrap();
        let root = CertificateBuilder::new(Profile::Root, SerialNumber::from(1u32),
            validity, root_name.clone(), root_public, &root_signer).unwrap()
            .build::<p384::ecdsa::DerSignature>().unwrap();

        let mut leaf_scalar = [0u8; 48];
        leaf_scalar[47] = 9;
        let (leaf_pem, leaf_spki) = if leaf_is_p384 {
            let key = p384::SecretKey::from_slice(&leaf_scalar).unwrap();
            let pem = key.to_pkcs8_pem(LineEnding::LF).unwrap().to_string();
            let spki = key.public_key().to_public_key_der().unwrap();
            (pem, spki.as_bytes().to_vec())
        } else {
            let key = p256::SecretKey::from_slice(&leaf_scalar[16..]).unwrap();
            let pem = key.to_pkcs8_pem(LineEnding::LF).unwrap().to_string();
            let spki = key.public_key().to_public_key_der().unwrap();
            (pem, spki.as_bytes().to_vec())
        };
        let leaf_public = SubjectPublicKeyInfoOwned::try_from(leaf_spki.as_slice()).unwrap();
        let leaf = CertificateBuilder::new(Profile::Leaf {
            issuer: root_name,
            enable_key_agreement: false,
            enable_key_encipherment: false,
        }, SerialNumber::from(serial), validity,
            Name::from_str("CN=Test App,O=Qingqi,C=CN").unwrap(),
            leaf_public, &root_signer).unwrap()
            .build::<p384::ecdsa::DerSignature>().unwrap();
        // AGC downloads often put the P-384 root before the P-256 leaf.
        let chain = root.to_pem(LineEnding::LF).unwrap() + &leaf.to_pem(LineEnding::LF).unwrap();
        (leaf_pem, chain)
    }

    #[test]
    fn renewed_certificate_uses_exact_profile_leaf_and_rejects_old_cache() {
        use hapsigner::{ApplicationVerification, InputFormat, ProfileSigner, SigningKey};
        use x509_cert::der::{Decode, EncodePem};
        let (key, original) = synthetic_chain_with_serial(false, 2);
        let (_, renewed) = synthetic_chain_with_serial(false, 3);
        let old_chain = SigningKey::cert_chain_from_bytes(original.as_bytes()).unwrap();
        let new_chain = SigningKey::cert_chain_from_bytes(renewed.as_bytes()).unwrap();
        assert_ne!(old_chain[0], new_chain[0]);
        let pem = x509_cert::Certificate::from_der(&old_chain[0]).unwrap()
            .to_pem(x509_cert::der::pem::LineEnding::LF).unwrap();
        let content = serde_json::to_vec(&serde_json::json!({
            "type":"debug", "bundle-info":{"development-certificate":pem}
        })).unwrap();
        let selected = super::chain_for_profile(&content, new_chain.clone()).unwrap();
        assert_eq!(selected, old_chain);
        let (_, unrelated) = synthetic_chain(true);
        assert!(super::chain_for_profile(&content,
            SigningKey::cert_chain_from_bytes(unrelated.as_bytes()).unwrap()).is_err());
        let signer = ProfileSigner::new(SigningKey {
            private_key_der: super::parse_ec_private_key(&key).unwrap().to_pkcs8_der().unwrap(),
            cert_chain: old_chain
        }, super::SigningAlgorithm::EcdsaSha256);
        let mut hap = ApplicationVerification {
            format: InputFormat::Zip, certificates: new_chain,
            profile: Some(signer.sign(&content).unwrap()), proof_of_rotation: None,
            properties: Vec::new(), algorithm: None, signing_block_version: Some(3)
        };
        assert!(super::verify_profile_signer(&hap).unwrap_err().contains("HAP signer differs"));
        hap.certificates = selected;
        assert!(super::verify_profile_signer(&hap).is_ok());
    }

    #[test]
    fn worker_requires_same_verified_profile_and_signer_as_main() {
        use hapsigner::{ApplicationVerification, InputFormat, ProfileSigner,
            SigningAlgorithm, SigningKey};
        let (key, certificates) = synthetic_chain(false);
        let chain = SigningKey::cert_chain_from_bytes(certificates.as_bytes()).unwrap();
        let private_key = super::parse_ec_private_key(&key).unwrap().to_pkcs8_der().unwrap();
        let signer = ProfileSigner::new(SigningKey {
            private_key_der: private_key, cert_chain: chain.clone()
        }, SigningAlgorithm::EcdsaSha256);
        let profile = signer.sign(br#"{"type":"debug","debug-info":{"device-ids":["device-a"]}}"#).unwrap();
        let main = ApplicationVerification {
            format: InputFormat::Zip, certificates: chain, profile: Some(profile),
            proof_of_rotation: None, properties: Vec::new(), algorithm: None,
            signing_block_version: Some(3)
        };
        let mut worker = main.clone();
        worker.certificates.reverse();
        assert!(super::matching_layer_authorization(&main, &worker).is_ok());
        worker.profile = Some(signer.sign(
            br#"{"type":"debug","debug-info":{"device-ids":["device-b"]}}"#).unwrap());
        assert!(super::matching_layer_authorization(&main, &worker).unwrap_err().contains("device profile differs"));
        worker.profile = main.profile.clone();
        worker.certificates.remove(0);
        assert!(super::matching_layer_authorization(&main, &worker).unwrap_err().contains("signing certificate differs"));
        worker = main.clone();
        worker.profile = None;
        assert!(super::matching_layer_authorization(&main, &worker).is_err());
    }

    #[test]
    fn certificate_match_handles_p384_issuer_and_leaf() {
        use std::ffi::CString;
        let dir = std::env::temp_dir().join(format!("qingqi-ec-chain-{}-{}",
            std::process::id(), super::NEXT_TEMP.fetch_add(1, std::sync::atomic::Ordering::Relaxed)));
        fs::create_dir(&dir).unwrap();
        let key_path = dir.join("key.pem");
        let cert_path = dir.join("chain.pem");
        let key_arg = CString::new(key_path.to_str().unwrap()).unwrap();
        let cert_arg = CString::new(cert_path.to_str().unwrap()).unwrap();

        let (p256_key, p256_chain) = synthetic_chain(false);
        fs::write(&key_path, &p256_key).unwrap();
        fs::write(&cert_path, &p256_chain).unwrap();
        assert_eq!(super::key_matches_certificate(key_arg.as_ptr(), cert_arg.as_ptr()).unwrap(), true);
        let leaf = hapsigner::SigningKey::cert_chain_from_bytes(p256_chain.as_bytes())
            .unwrap().remove(0);
        let mut fingerprint = [0u8; 65];
        let mut error = [0i8; 128];
        assert_eq!(super::qingqi_certificate_fingerprint(cert_arg.as_ptr(),
            fingerprint.as_mut_ptr(), fingerprint.len(), error.as_mut_ptr(), error.len()), 0);
        assert_eq!(std::str::from_utf8(&fingerprint[..64]).unwrap(),
            format!("{:x}", Sha256::digest(&leaf)).to_uppercase());

        let (p384_key, p384_chain) = synthetic_chain(true);
        fs::write(&cert_path, &p384_chain).unwrap();
        assert_eq!(super::key_matches_certificate(key_arg.as_ptr(), cert_arg.as_ptr()).unwrap(), false);
        fs::write(&key_path, &p384_key).unwrap();
        assert_eq!(super::key_matches_certificate(key_arg.as_ptr(), cert_arg.as_ptr()).unwrap(), true);

        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn csr_is_signed_by_the_same_p256_key() {
        use p256::ecdsa::{signature::Verifier, DerSignature, VerifyingKey};
        use p256::elliptic_curve::sec1::ToEncodedPoint;
        use p256::pkcs8::{DecodePublicKey, EncodePrivateKey};
        use x509_cert::der::{pem::LineEnding, DecodePem, Encode};
        use x509_cert::request::CertReq;

        let mut scalar = [0u8; 32];
        scalar[31] = 1;
        let key = p256::SecretKey::from_slice(&scalar).unwrap();
        let pem = key.to_pkcs8_pem(LineEnding::LF).unwrap();
        let request_pem = super::csr_from_private_key(pem.as_str()).unwrap();
        let request = CertReq::from_pem(&request_pem).unwrap();
        let public_der = request.info.public_key.to_der().unwrap();
        let public = VerifyingKey::from_public_key_der(&public_der).unwrap();
        assert_eq!(public.to_encoded_point(false), key.public_key().to_encoded_point(false));
        let signature = DerSignature::from_bytes(request.signature.raw_bytes()).unwrap();
        public.verify(&request.info.to_der().unwrap(), &signature).unwrap();
    }

    #[test]
    fn csr_is_signed_by_the_same_p384_key() {
        use p384::ecdsa::{signature::Verifier, DerSignature, VerifyingKey};
        use p384::elliptic_curve::sec1::ToEncodedPoint;
        use p384::pkcs8::{DecodePublicKey, EncodePrivateKey};
        use x509_cert::der::{pem::LineEnding, DecodePem, Encode};
        use x509_cert::request::CertReq;

        let mut scalar = [0u8; 48];
        scalar[47] = 1;
        let key = p384::SecretKey::from_slice(&scalar).unwrap();
        let pem = key.to_pkcs8_pem(LineEnding::LF).unwrap();
        let request_pem = super::csr_from_private_key(pem.as_str()).unwrap();
        let request = CertReq::from_pem(&request_pem).unwrap();
        let public_der = request.info.public_key.to_der().unwrap();
        let public = VerifyingKey::from_public_key_der(&public_der).unwrap();
        assert_eq!(public.to_encoded_point(false), key.public_key().to_encoded_point(false));
        let signature = DerSignature::from_bytes(request.signature.raw_bytes()).unwrap();
        public.verify(&request.info.to_der().unwrap(), &signature).unwrap();
    }

    #[test]
    fn ffi_material_error_is_reported_and_bounded() {
        use std::ffi::{CStr, CString};
        let missing = CString::new("/nonexistent/qingqi-test-private-key.pem").unwrap();
        let mut error = [0i8; 256];
        let result = super::qingqi_key_matches_certificate(
            missing.as_ptr(), missing.as_ptr(), error.as_mut_ptr(), error.len());
        assert_eq!(result, -1);
        let detail = unsafe { CStr::from_ptr(error.as_ptr()) }.to_str().unwrap();
        assert!(detail.contains("cannot read private key"));
        assert!(detail.contains("qingqi-test-private-key.pem"));
        let mut short = [42i8; 9];
        super::qingqi_key_matches_certificate(
            missing.as_ptr(), missing.as_ptr(), short.as_mut_ptr(), 8);
        assert_eq!(short[7], 0);
        assert_eq!(short[8], 42);
    }

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
