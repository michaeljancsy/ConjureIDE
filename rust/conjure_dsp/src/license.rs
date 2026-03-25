use base64::Engine;
use ed25519_dalek::{Signature, Verifier, VerifyingKey};
use serde::Deserialize;

/// Ed25519 public key, XOR-masked to prevent trivial extraction from the binary.
/// To regenerate: cd tools/generate-license && cargo run -- --init
/// Then XOR each byte with the corresponding MASK byte below.
const MASKED_KEY: [u8; 32] = [
    0x90 ^ 0xa3, 0x7f ^ 0x5d, 0x2f ^ 0xe1, 0x36 ^ 0x74,
    0x00 ^ 0xb8, 0x0f ^ 0x9c, 0x0b ^ 0x27, 0x16 ^ 0xf0,
    0x5c ^ 0x63, 0xed ^ 0x4a, 0x38 ^ 0xd5, 0xd9 ^ 0x19,
    0x46 ^ 0x8e, 0x51 ^ 0xf7, 0xee ^ 0x3b, 0x64 ^ 0xac,
    0x29 ^ 0xc6, 0x9e ^ 0x02, 0x6f ^ 0x78, 0x7e ^ 0xd3,
    0xf2 ^ 0x4f, 0xcb ^ 0xb1, 0xdf ^ 0x5a, 0x0b ^ 0xe9,
    0xc0 ^ 0x37, 0xa5 ^ 0x8d, 0xda ^ 0x6c, 0x03 ^ 0xfa,
    0x14 ^ 0xc1, 0x51 ^ 0x53, 0xff ^ 0xa6, 0x7e ^ 0x1b,
];

const MASK: [u8; 32] = [
    0xa3, 0x5d, 0xe1, 0x74, 0xb8, 0x9c, 0x27, 0xf0,
    0x63, 0x4a, 0xd5, 0x19, 0x8e, 0xf7, 0x3b, 0xac,
    0xc6, 0x02, 0x78, 0xd3, 0x4f, 0xb1, 0x5a, 0xe9,
    0x37, 0x8d, 0x6c, 0xfa, 0xc1, 0x53, 0xa6, 0x1b,
];

/// Recover the public key at runtime by XOR-unmasking.
fn public_key_bytes_decoded() -> [u8; 32] {
    let mut key = [0u8; 32];
    for i in 0..32 {
        key[i] = MASKED_KEY[i] ^ MASK[i];
    }
    key
}

#[derive(Debug, Deserialize)]
pub struct LicensePayload {
    pub email: String,
    pub product: String,
    pub created: String,
}

#[derive(Debug)]
pub enum LicenseError {
    /// Missing "." separator or wrong segment count.
    InvalidFormat,
    /// Base64 decoding failed.
    Base64Decode,
    /// Ed25519 signature verification failed.
    InvalidSignature,
    /// JSON parse failed or wrong product field.
    InvalidPayload,
    /// Embedded public key is malformed.
    InvalidPublicKey,
}

impl std::fmt::Display for LicenseError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidFormat => write!(f, "Invalid serial format"),
            Self::Base64Decode => write!(f, "Failed to decode serial"),
            Self::InvalidSignature => write!(f, "Invalid license signature"),
            Self::InvalidPayload => write!(f, "Invalid license payload"),
            Self::InvalidPublicKey => write!(f, "Invalid public key"),
        }
    }
}

/// Verify a serial key using a specific public key.
///
/// Serial format: `base64(json_payload).base64(ed25519_signature)`
///
/// The signature is verified against the raw JSON bytes (not the base64 encoding).
/// Returns the parsed payload on success, or an error.
pub fn verify_with_key(
    serial: &str,
    public_key_bytes: &[u8; 32],
) -> Result<LicensePayload, LicenseError> {
    let parts: Vec<&str> = serial.trim().splitn(2, '.').collect();
    if parts.len() != 2 {
        return Err(LicenseError::InvalidFormat);
    }

    let engine = base64::engine::general_purpose::STANDARD;

    let payload_bytes = engine
        .decode(parts[0])
        .map_err(|_| LicenseError::Base64Decode)?;
    let sig_bytes = engine
        .decode(parts[1])
        .map_err(|_| LicenseError::Base64Decode)?;

    let signature =
        Signature::from_slice(&sig_bytes).map_err(|_| LicenseError::InvalidSignature)?;
    let verifying_key =
        VerifyingKey::from_bytes(public_key_bytes).map_err(|_| LicenseError::InvalidPublicKey)?;

    verifying_key
        .verify(&payload_bytes, &signature)
        .map_err(|_| LicenseError::InvalidSignature)?;

    let payload: LicensePayload =
        serde_json::from_slice(&payload_bytes).map_err(|_| LicenseError::InvalidPayload)?;

    if payload.product != "conjuredsp" {
        return Err(LicenseError::InvalidPayload);
    }

    Ok(payload)
}

/// Return the embedded public key bytes (32 bytes).
/// Only available in debug builds — used by the UI to display a fingerprint for debugging key mismatches.
#[cfg(debug_assertions)]
pub fn public_key_bytes() -> [u8; 32] {
    public_key_bytes_decoded()
}

/// Verify a serial key using the embedded production public key.
///
/// Serial format: `base64(json_payload).base64(ed25519_signature)`
///
/// Returns the parsed payload on success, or an error.
pub fn verify_license(serial: &str) -> Result<LicensePayload, LicenseError> {
    let key = public_key_bytes_decoded();
    verify_with_key(serial, &key)
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::Engine;

    /// Generate a test keypair and return (signing_key, verifying_key_bytes).
    fn test_keypair() -> (ed25519_dalek::SigningKey, [u8; 32]) {
        use ed25519_dalek::SigningKey;
        use rand::rngs::OsRng;
        let signing_key = SigningKey::generate(&mut OsRng);
        let verifying_key_bytes = signing_key.verifying_key().to_bytes();
        (signing_key, verifying_key_bytes)
    }

    /// Sign a payload and return a serial string.
    fn make_serial(signing_key: &ed25519_dalek::SigningKey, payload_json: &str) -> String {
        use ed25519_dalek::Signer;
        let engine = base64::engine::general_purpose::STANDARD;
        let payload_b64 = engine.encode(payload_json.as_bytes());
        let signature = signing_key.sign(payload_json.as_bytes());
        let sig_b64 = engine.encode(signature.to_bytes());
        format!("{}.{}", payload_b64, sig_b64)
    }

    #[test]
    fn test_valid_license_verifies() {
        let (signing_key, pub_bytes) = test_keypair();
        let payload = r#"{"email":"test@example.com","product":"conjuredsp","created":"2026-03-05"}"#;
        let serial = make_serial(&signing_key, payload);

        let result = verify_with_key(&serial, &pub_bytes);
        assert!(result.is_ok());
        let p = result.unwrap();
        assert_eq!(p.email, "test@example.com");
        assert_eq!(p.product, "conjuredsp");
        assert_eq!(p.created, "2026-03-05");
    }

    #[test]
    fn test_tampered_payload_fails() {
        let (signing_key, pub_bytes) = test_keypair();
        let payload = r#"{"email":"test@example.com","product":"conjuredsp","created":"2026-03-05"}"#;
        let serial = make_serial(&signing_key, payload);

        // Tamper: replace payload portion with different email
        let tampered_payload = r#"{"email":"hacker@evil.com","product":"conjuredsp","created":"2026-03-05"}"#;
        let engine = base64::engine::general_purpose::STANDARD;
        let tampered_b64 = engine.encode(tampered_payload.as_bytes());
        let parts: Vec<&str> = serial.splitn(2, '.').collect();
        let tampered_serial = format!("{}.{}", tampered_b64, parts[1]);

        let result = verify_with_key(&tampered_serial, &pub_bytes);
        assert!(matches!(result, Err(LicenseError::InvalidSignature)));
    }

    #[test]
    fn test_wrong_public_key_fails() {
        let (signing_key, _pub_bytes) = test_keypair();
        let (_, wrong_pub_bytes) = test_keypair();
        let payload = r#"{"email":"test@example.com","product":"conjuredsp","created":"2026-03-05"}"#;
        let serial = make_serial(&signing_key, payload);

        let result = verify_with_key(&serial, &wrong_pub_bytes);
        assert!(matches!(result, Err(LicenseError::InvalidSignature)));
    }

    #[test]
    fn test_wrong_product_fails() {
        let (signing_key, pub_bytes) = test_keypair();
        let payload = r#"{"email":"test@example.com","product":"other_plugin","created":"2026-03-05"}"#;
        let serial = make_serial(&signing_key, payload);

        let result = verify_with_key(&serial, &pub_bytes);
        assert!(matches!(result, Err(LicenseError::InvalidPayload)));
    }

    #[test]
    fn test_malformed_serial_no_dot() {
        let (_, pub_bytes) = test_keypair();
        let result = verify_with_key("nodothere", &pub_bytes);
        assert!(matches!(result, Err(LicenseError::InvalidFormat)));
    }

    #[test]
    fn test_invalid_base64() {
        let (_, pub_bytes) = test_keypair();
        let result = verify_with_key("!!!.!!!", &pub_bytes);
        assert!(matches!(result, Err(LicenseError::Base64Decode)));
    }

    #[test]
    fn test_empty_serial() {
        let (_, pub_bytes) = test_keypair();
        let result = verify_with_key("", &pub_bytes);
        assert!(matches!(result, Err(LicenseError::InvalidFormat)));
    }

    #[test]
    fn test_valid_base64_but_invalid_json() {
        let (_, pub_bytes) = test_keypair();
        let engine = base64::engine::general_purpose::STANDARD;
        let payload_b64 = engine.encode(b"not json");
        let fake_sig_b64 = engine.encode(&[0u8; 64]);
        let serial = format!("{}.{}", payload_b64, fake_sig_b64);

        let result = verify_with_key(&serial, &pub_bytes);
        // Will fail at signature verification before JSON parse
        assert!(result.is_err());
    }

    #[test]
    fn test_serial_with_whitespace_trimmed() {
        let (signing_key, pub_bytes) = test_keypair();
        let payload = r#"{"email":"test@example.com","product":"conjuredsp","created":"2026-03-05"}"#;
        let serial = make_serial(&signing_key, payload);

        // Add whitespace/newlines
        let padded = format!("  {} \n", serial);
        let result = verify_with_key(&padded, &pub_bytes);
        assert!(result.is_ok());
    }

    #[test]
    fn test_verify_license_uses_embedded_key() {
        // A random test keypair won't match the embedded production key
        let (signing_key, _) = test_keypair();
        let payload = r#"{"email":"test@example.com","product":"conjuredsp","created":"2026-03-05"}"#;
        let serial = make_serial(&signing_key, payload);

        // verify_license uses the production PUBLIC_KEY_BYTES — a random key's serial should fail
        let result = verify_license(&serial);
        assert!(result.is_err());
    }
}
