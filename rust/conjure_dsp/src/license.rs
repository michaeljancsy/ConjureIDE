use base64::Engine;
use ed25519_dalek::{Signature, Verifier, VerifyingKey};
use serde::Deserialize;

/// Ed25519 public key for the subscription server, XOR-masked to prevent trivial extraction.
/// This key is used to verify subscription tokens signed by the server.
/// To update: generate a new keypair for the server, XOR each byte with MASK, and replace.
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

/// Subscription token payload, signed by the server.
#[derive(Debug, Deserialize)]
pub struct TokenPayload {
    /// Paddle subscription ID (e.g. "sub_abc123")
    pub sub: String,
    pub email: String,
    /// Subscription status: "active", "paused", "canceled", "past_due"
    pub status: String,
    /// ISO 8601 timestamp — token is valid until this time
    pub valid_until: String,
    /// ISO 8601 timestamp — when the token was issued
    pub issued_at: String,
    pub product: String,
}

/// Subscription status as determined by token verification + expiry check.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum SubscriptionStatus {
    Active = 0,
    GracePeriod = 1,
    Expired = 2,
    Cancelled = 3,
    NoSubscription = 4,
}

impl SubscriptionStatus {
    pub fn from_u8(v: u8) -> Self {
        match v {
            0 => Self::Active,
            1 => Self::GracePeriod,
            2 => Self::Expired,
            3 => Self::Cancelled,
            _ => Self::NoSubscription,
        }
    }

    /// Whether this status should grant full (licensed) access.
    pub fn is_licensed(self) -> bool {
        matches!(self, Self::Active | Self::GracePeriod)
    }
}

#[derive(Debug)]
pub enum LicenseError {
    InvalidFormat,
    Base64Decode,
    InvalidSignature,
    InvalidPayload,
    InvalidPublicKey,
}

impl std::fmt::Display for LicenseError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidFormat => write!(f, "Invalid token format"),
            Self::Base64Decode => write!(f, "Failed to decode token"),
            Self::InvalidSignature => write!(f, "Invalid token signature"),
            Self::InvalidPayload => write!(f, "Invalid token payload"),
            Self::InvalidPublicKey => write!(f, "Invalid public key"),
        }
    }
}

/// Grace period in seconds (7 days).
const GRACE_PERIOD_SECONDS: i64 = 7 * 24 * 60 * 60;

/// Verify a token's Ed25519 signature using a specific public key.
///
/// Token format: `base64(json_payload).base64(ed25519_signature)`
/// The signature is verified against the raw JSON bytes.
pub fn verify_with_key(
    token: &str,
    public_key_bytes: &[u8; 32],
) -> Result<TokenPayload, LicenseError> {
    let parts: Vec<&str> = token.trim().splitn(2, '.').collect();
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

    let payload: TokenPayload =
        serde_json::from_slice(&payload_bytes).map_err(|_| LicenseError::InvalidPayload)?;

    if payload.product != "conjuredsp" {
        return Err(LicenseError::InvalidPayload);
    }

    Ok(payload)
}

/// Verify a subscription token using the embedded server public key.
pub fn verify_token(token: &str) -> Result<TokenPayload, LicenseError> {
    let key = public_key_bytes_decoded();
    verify_with_key(token, &key)
}

/// Parse an ISO 8601 timestamp (YYYY-MM-DDTHH:MM:SSZ or with offset) to Unix seconds.
/// Supports: "2026-04-01T00:00:00Z" and "2026-04-01T00:00:00.000Z"
/// Returns None on parse failure.
fn parse_iso8601_to_unix(s: &str) -> Option<i64> {
    // Minimal parser for the subset of ISO 8601 the server produces.
    // Format: YYYY-MM-DDTHH:MM:SS[.fractional]Z
    let s = s.trim();
    let s = s.strip_suffix('Z').or_else(|| {
        // Also handle +00:00 suffix
        s.strip_suffix("+00:00")
    })?;

    let (date_part, time_part) = s.split_once('T')?;
    let date_parts: Vec<&str> = date_part.split('-').collect();
    if date_parts.len() != 3 {
        return None;
    }
    let year: i64 = date_parts[0].parse().ok()?;
    let month: i64 = date_parts[1].parse().ok()?;
    let day: i64 = date_parts[2].parse().ok()?;

    // Strip fractional seconds if present
    let time_str = time_part.split('.').next()?;
    let time_parts: Vec<&str> = time_str.split(':').collect();
    if time_parts.len() != 3 {
        return None;
    }
    let hour: i64 = time_parts[0].parse().ok()?;
    let min: i64 = time_parts[1].parse().ok()?;
    let sec: i64 = time_parts[2].parse().ok()?;

    // Convert to Unix timestamp using a simple algorithm (valid for 2000-2099).
    // Days from Unix epoch (1970-01-01) to the given date.
    let days = days_from_epoch(year, month, day)?;
    Some(days * 86400 + hour * 3600 + min * 60 + sec)
}

/// Days from 1970-01-01 to the given date. Simple algorithm for 2000-2099 range.
fn days_from_epoch(year: i64, month: i64, day: i64) -> Option<i64> {
    if year < 1970 || month < 1 || month > 12 || day < 1 || day > 31 {
        return None;
    }
    // Adjust for March-based year (simplifies leap year handling)
    let (y, m) = if month <= 2 {
        (year - 1, month + 9)
    } else {
        (year, month - 3)
    };
    let era = y / 400;
    let yoe = y - era * 400;
    let doy = (153 * m + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146097 + doe - 719468; // Offset from Unix epoch
    Some(days)
}

/// Check a token's subscription status given the current Unix time.
///
/// This does NOT verify the signature — call `verify_token` or `verify_with_key` first.
pub fn check_token_status(payload: &TokenPayload, now_unix: i64) -> SubscriptionStatus {
    // If the subscription was cancelled, it's cancelled regardless of valid_until.
    if payload.status == "canceled" {
        return SubscriptionStatus::Cancelled;
    }

    let valid_until_unix = match parse_iso8601_to_unix(&payload.valid_until) {
        Some(t) => t,
        None => return SubscriptionStatus::Expired,
    };

    if now_unix < valid_until_unix {
        // Token is still within its validity period
        if payload.status == "active" {
            SubscriptionStatus::Active
        } else if payload.status == "past_due" {
            SubscriptionStatus::GracePeriod
        } else {
            // paused or unknown — treat as grace
            SubscriptionStatus::GracePeriod
        }
    } else {
        // Token has expired
        let seconds_past = now_unix - valid_until_unix;
        if seconds_past <= GRACE_PERIOD_SECONDS {
            SubscriptionStatus::GracePeriod
        } else {
            SubscriptionStatus::Expired
        }
    }
}

/// Returns the grace deadline (valid_until + 7 days) as Unix seconds for UI display.
pub fn grace_deadline_from_token(payload: &TokenPayload) -> i64 {
    parse_iso8601_to_unix(&payload.valid_until)
        .map(|t| t + GRACE_PERIOD_SECONDS)
        .unwrap_or(0)
}

/// Return the embedded public key bytes (32 bytes).
/// Only available in debug builds — used by the UI for diagnostics.
#[cfg(debug_assertions)]
pub fn public_key_bytes() -> [u8; 32] {
    public_key_bytes_decoded()
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::Engine;

    fn test_keypair() -> (ed25519_dalek::SigningKey, [u8; 32]) {
        use ed25519_dalek::SigningKey;
        use rand::rngs::OsRng;
        let signing_key = SigningKey::generate(&mut OsRng);
        let verifying_key_bytes = signing_key.verifying_key().to_bytes();
        (signing_key, verifying_key_bytes)
    }

    fn make_token(signing_key: &ed25519_dalek::SigningKey, payload_json: &str) -> String {
        use ed25519_dalek::Signer;
        let engine = base64::engine::general_purpose::STANDARD;
        let payload_b64 = engine.encode(payload_json.as_bytes());
        let signature = signing_key.sign(payload_json.as_bytes());
        let sig_b64 = engine.encode(signature.to_bytes());
        format!("{}.{}", payload_b64, sig_b64)
    }

    #[test]
    fn test_valid_token_verifies() {
        let (signing_key, pub_bytes) = test_keypair();
        let payload = r#"{"sub":"sub_123","email":"test@example.com","status":"active","valid_until":"2099-01-01T00:00:00Z","issued_at":"2026-03-25T00:00:00Z","product":"conjuredsp"}"#;
        let token = make_token(&signing_key, payload);

        let result = verify_with_key(&token, &pub_bytes);
        assert!(result.is_ok());
        let p = result.unwrap();
        assert_eq!(p.sub, "sub_123");
        assert_eq!(p.email, "test@example.com");
        assert_eq!(p.status, "active");
    }

    #[test]
    fn test_tampered_token_fails() {
        let (signing_key, pub_bytes) = test_keypair();
        let payload = r#"{"sub":"sub_123","email":"test@example.com","status":"active","valid_until":"2099-01-01T00:00:00Z","issued_at":"2026-03-25T00:00:00Z","product":"conjuredsp"}"#;
        let token = make_token(&signing_key, payload);

        let tampered = r#"{"sub":"sub_123","email":"hacker@evil.com","status":"active","valid_until":"2099-01-01T00:00:00Z","issued_at":"2026-03-25T00:00:00Z","product":"conjuredsp"}"#;
        let engine = base64::engine::general_purpose::STANDARD;
        let tampered_b64 = engine.encode(tampered.as_bytes());
        let parts: Vec<&str> = token.splitn(2, '.').collect();
        let tampered_token = format!("{}.{}", tampered_b64, parts[1]);

        let result = verify_with_key(&tampered_token, &pub_bytes);
        assert!(matches!(result, Err(LicenseError::InvalidSignature)));
    }

    #[test]
    fn test_wrong_product_fails() {
        let (signing_key, pub_bytes) = test_keypair();
        let payload = r#"{"sub":"sub_123","email":"test@example.com","status":"active","valid_until":"2099-01-01T00:00:00Z","issued_at":"2026-03-25T00:00:00Z","product":"other"}"#;
        let token = make_token(&signing_key, payload);

        let result = verify_with_key(&token, &pub_bytes);
        assert!(matches!(result, Err(LicenseError::InvalidPayload)));
    }

    #[test]
    fn test_malformed_token_no_dot() {
        let (_, pub_bytes) = test_keypair();
        assert!(matches!(
            verify_with_key("nodothere", &pub_bytes),
            Err(LicenseError::InvalidFormat)
        ));
    }

    #[test]
    fn test_empty_token() {
        let (_, pub_bytes) = test_keypair();
        assert!(matches!(
            verify_with_key("", &pub_bytes),
            Err(LicenseError::InvalidFormat)
        ));
    }

    #[test]
    fn test_token_with_whitespace_trimmed() {
        let (signing_key, pub_bytes) = test_keypair();
        let payload = r#"{"sub":"sub_123","email":"test@example.com","status":"active","valid_until":"2099-01-01T00:00:00Z","issued_at":"2026-03-25T00:00:00Z","product":"conjuredsp"}"#;
        let token = make_token(&signing_key, payload);
        let padded = format!("  {} \n", token);
        assert!(verify_with_key(&padded, &pub_bytes).is_ok());
    }

    // Status check tests

    #[test]
    fn test_token_status_active() {
        let payload = TokenPayload {
            sub: "sub_123".into(),
            email: "test@example.com".into(),
            status: "active".into(),
            valid_until: "2099-01-01T00:00:00Z".into(),
            issued_at: "2026-03-25T00:00:00Z".into(),
            product: "conjuredsp".into(),
        };
        // now_unix = 2026-03-25 ~= 1774588800
        let status = check_token_status(&payload, 1774588800);
        assert_eq!(status, SubscriptionStatus::Active);
        assert!(status.is_licensed());
    }

    #[test]
    fn test_token_status_grace_period() {
        let payload = TokenPayload {
            sub: "sub_123".into(),
            email: "test@example.com".into(),
            status: "active".into(),
            // Expired 3 days ago from our "now"
            valid_until: "2026-03-22T00:00:00Z".into(),
            issued_at: "2026-03-15T00:00:00Z".into(),
            product: "conjuredsp".into(),
        };
        let now = parse_iso8601_to_unix("2026-03-25T00:00:00Z").unwrap();
        let status = check_token_status(&payload, now);
        assert_eq!(status, SubscriptionStatus::GracePeriod);
        assert!(status.is_licensed());
    }

    #[test]
    fn test_token_status_expired_beyond_grace() {
        let payload = TokenPayload {
            sub: "sub_123".into(),
            email: "test@example.com".into(),
            status: "active".into(),
            // Expired 10 days ago
            valid_until: "2026-03-15T00:00:00Z".into(),
            issued_at: "2026-03-08T00:00:00Z".into(),
            product: "conjuredsp".into(),
        };
        let now = parse_iso8601_to_unix("2026-03-25T00:00:00Z").unwrap();
        let status = check_token_status(&payload, now);
        assert_eq!(status, SubscriptionStatus::Expired);
        assert!(!status.is_licensed());
    }

    #[test]
    fn test_token_status_cancelled() {
        let payload = TokenPayload {
            sub: "sub_123".into(),
            email: "test@example.com".into(),
            status: "canceled".into(),
            valid_until: "2099-01-01T00:00:00Z".into(),
            issued_at: "2026-03-25T00:00:00Z".into(),
            product: "conjuredsp".into(),
        };
        let status = check_token_status(&payload, 1774588800);
        assert_eq!(status, SubscriptionStatus::Cancelled);
        assert!(!status.is_licensed());
    }

    #[test]
    fn test_token_status_past_due() {
        let payload = TokenPayload {
            sub: "sub_123".into(),
            email: "test@example.com".into(),
            status: "past_due".into(),
            valid_until: "2099-01-01T00:00:00Z".into(),
            issued_at: "2026-03-25T00:00:00Z".into(),
            product: "conjuredsp".into(),
        };
        let status = check_token_status(&payload, 1774588800);
        assert_eq!(status, SubscriptionStatus::GracePeriod);
        assert!(status.is_licensed());
    }

    #[test]
    fn test_parse_iso8601() {
        let ts = parse_iso8601_to_unix("2026-03-25T00:00:00Z");
        assert!(ts.is_some());
        let ts = ts.unwrap();
        // 2026-03-25 should be approximately 1774588800
        assert!(ts > 1774000000 && ts < 1775000000);
    }

    #[test]
    fn test_parse_iso8601_with_fraction() {
        let ts = parse_iso8601_to_unix("2026-03-25T12:30:45.123Z");
        assert!(ts.is_some());
    }

    #[test]
    fn test_grace_deadline() {
        let payload = TokenPayload {
            sub: "sub_123".into(),
            email: "test@example.com".into(),
            status: "active".into(),
            valid_until: "2026-04-01T00:00:00Z".into(),
            issued_at: "2026-03-25T00:00:00Z".into(),
            product: "conjuredsp".into(),
        };
        let deadline = grace_deadline_from_token(&payload);
        let valid_until = parse_iso8601_to_unix("2026-04-01T00:00:00Z").unwrap();
        assert_eq!(deadline, valid_until + 7 * 24 * 60 * 60);
    }

    #[test]
    fn test_verify_token_uses_embedded_key() {
        // A random test keypair won't match the embedded production key
        let (signing_key, _) = test_keypair();
        let payload = r#"{"sub":"sub_123","email":"test@example.com","status":"active","valid_until":"2099-01-01T00:00:00Z","issued_at":"2026-03-25T00:00:00Z","product":"conjuredsp"}"#;
        let token = make_token(&signing_key, payload);
        assert!(verify_token(&token).is_err());
    }
}
