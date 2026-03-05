//! BearBone license key generator.
//!
//! First run: generates an Ed25519 keypair, saves the private key to `keypair.bin`,
//! and prints the public key bytes for embedding in `license.rs`.
//!
//! Subsequent runs: signs a license payload for the given email and prints the serial.
//!
//! Usage:
//!   cargo run -- --email user@example.com
//!   cargo run -- --email user@example.com --init   # force regenerate keypair

use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use clap::Parser;
use ed25519_dalek::{Signer, SigningKey, VerifyingKey};
use rand::rngs::OsRng;
use serde_json::json;
use std::fs;
use std::path::PathBuf;

#[derive(Parser)]
#[command(name = "generate-license", about = "Generate BearBone license keys")]
struct Cli {
    /// Email address for the license
    #[arg(long)]
    email: Option<String>,

    /// Force regenerate keypair (overwrites existing keypair.bin)
    #[arg(long)]
    init: bool,
}

fn keypair_path() -> PathBuf {
    let exe_dir = std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(|d| d.to_path_buf()))
        .unwrap_or_else(|| PathBuf::from("."));
    // Store next to executable, but fall back to cwd
    let candidate = exe_dir.join("keypair.bin");
    if candidate.exists() {
        return candidate;
    }
    // Also check cwd (common during development)
    PathBuf::from("keypair.bin")
}

fn load_or_create_keypair(force_init: bool) -> SigningKey {
    let path = keypair_path();

    if !force_init && path.exists() {
        let bytes = fs::read(&path).expect("Failed to read keypair.bin");
        if bytes.len() != 32 {
            eprintln!("Error: keypair.bin has invalid size ({}), expected 32 bytes", bytes.len());
            std::process::exit(1);
        }
        let secret: [u8; 32] = bytes.try_into().unwrap();
        let signing_key = SigningKey::from_bytes(&secret);
        eprintln!("Loaded existing keypair from {}", path.display());
        return signing_key;
    }

    // Generate new keypair
    let signing_key = SigningKey::generate(&mut OsRng);
    fs::write(&path, signing_key.to_bytes()).expect("Failed to write keypair.bin");

    let verifying_key: VerifyingKey = (&signing_key).into();
    let pub_bytes = verifying_key.to_bytes();

    eprintln!("Generated new keypair. Private key saved to: {}", path.display());
    eprintln!();
    eprintln!("=== PUBLIC KEY BYTES (embed in license.rs) ===");
    eprintln!("const PUBLIC_KEY_BYTES: [u8; 32] = [");
    for (i, byte) in pub_bytes.iter().enumerate() {
        if i % 8 == 0 {
            eprint!("    ");
        }
        eprint!("0x{:02x}, ", byte);
        if i % 8 == 7 {
            eprintln!();
        }
    }
    eprintln!("];");
    eprintln!("==============================================");
    eprintln!();

    signing_key
}

fn generate_serial(signing_key: &SigningKey, email: &str) -> String {
    let today = chrono_free_date();

    let payload = json!({
        "email": email,
        "product": "bearbone",
        "created": today
    });

    let payload_json = serde_json::to_string(&payload).unwrap();
    let payload_b64 = BASE64.encode(payload_json.as_bytes());

    let signature = signing_key.sign(payload_json.as_bytes());
    let sig_b64 = BASE64.encode(signature.to_bytes());

    format!("{}.{}", payload_b64, sig_b64)
}

/// Returns today's date as YYYY-MM-DD without pulling in the chrono crate.
fn chrono_free_date() -> String {
    use std::process::Command;
    let output = Command::new("date")
        .arg("+%Y-%m-%d")
        .output()
        .expect("Failed to run date command");
    String::from_utf8(output.stdout)
        .unwrap()
        .trim()
        .to_string()
}

fn main() {
    let cli = Cli::parse();

    let signing_key = load_or_create_keypair(cli.init);

    if let Some(email) = cli.email {
        let serial = generate_serial(&signing_key, &email);
        println!("{}", serial);
        eprintln!("License generated for: {}", email);
    } else if !cli.init {
        eprintln!("No --email provided. Use --email <address> to generate a license.");
        eprintln!("Use --init to (re)generate the keypair.");
        std::process::exit(1);
    }
}
