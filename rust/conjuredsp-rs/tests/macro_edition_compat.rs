//! Validate that the `setup!`, `params!`, `telemetry!`, `latency!`,
//! `nam!`, `nams!`, and `state!` macros emit code that compiles under
//! both `--edition 2021` *and* `--edition 2024`.
//!
//! Step 6 of the modernization plan flips user-script compilation from
//! 2021 to 2024, so the macros must work under both editions during the
//! interval where the crate has been modernized but the user-facing
//! flag hasn't flipped yet. See plans/an-ai-had-this-starry-moler.md.
//!
//! The test shells out to the bundled `rustc-dist/bin/rustc` because
//! that's the toolchain that compiles user presets in production. Skips
//! gracefully when the bundled toolchain isn't present (fresh clone
//! pre-`setup-rustc.sh`).

use std::path::{Path, PathBuf};
use std::process::Command;

fn repo_root() -> PathBuf {
    // CARGO_MANIFEST_DIR points at rust/conjuredsp-rs/. Walk up two to repo root.
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .to_path_buf()
}

fn bundled_rustc() -> PathBuf {
    repo_root().join("rustc-dist/bin/rustc")
}

fn bundled_sysroot() -> PathBuf {
    repo_root().join("rustc-dist")
}

const FIXTURE: &str = r#"
#![allow(unused, dead_code)]
use conjuredsp::*;

params! {
    GAIN = db().min(-24.0).max(12.0).default(0.0),
    MIX  = mix(),
}

telemetry! {
    LEVEL = scalar_telemetry(),
    HIST  = vector_telemetry(),
}

latency!(0);

state!(max_bytes = 1024);

nams! {
    DRIVE = "tone3000://19/56",
    CAB   = "tone3000://19/57",
}

persist!(SCALAR: f64 = 0.0);
persist_mut!(BUF: [f32; 8] = [0.0; 8]);

// Canonical zero-arg entry point via process!. The `#[unsafe(no_mangle)]`
// attribute the macro emits works under both editions (accepted since
// Rust 1.82), so the fixture doesn't need to fork on edition.
process! { cx =>
    let _g = cx.param(GAIN);
    cx.set_telemetry_scalar(LEVEL, 0.0);
    let _bytes = cx.state_bytes();
    let _gen = cx.state_generation();
    let _s = SCALAR.get();
    SCALAR.set(_s + 1.0);
    BUF.with_mut(|b| b[0] = 1.0);
}
"#;

fn build_rlib(rustc: &Path, sysroot: &Path, edition: &str, src: &Path, out: &Path) -> bool {
    let status = Command::new(rustc)
        .args([
            "--target",
            "wasm32-wasip1",
            "--edition",
            edition,
            "--crate-type",
            "rlib",
            "--crate-name",
            "conjuredsp",
            "-C",
            "opt-level=2",
            "--sysroot",
            sysroot.to_str().unwrap(),
            "-o",
            out.to_str().unwrap(),
            src.to_str().unwrap(),
        ])
        .env(
            "DYLD_LIBRARY_PATH",
            sysroot.join("lib").to_str().unwrap(),
        )
        .status()
        .expect("spawn rustc");
    status.success()
}

fn build_fixture(rustc: &Path, sysroot: &Path, edition: &str, rlib: &Path, src: &Path, out: &Path) -> bool {
    let status = Command::new(rustc)
        .args([
            "--target",
            "wasm32-wasip1",
            "--edition",
            edition,
            "--crate-type",
            "cdylib",
            "-C",
            "opt-level=2",
            "--sysroot",
            sysroot.to_str().unwrap(),
            "--extern",
            &format!("conjuredsp={}", rlib.to_str().unwrap()),
            "-o",
            out.to_str().unwrap(),
            src.to_str().unwrap(),
        ])
        .env(
            "DYLD_LIBRARY_PATH",
            sysroot.join("lib").to_str().unwrap(),
        )
        .status()
        .expect("spawn rustc");
    status.success()
}

fn run_compat_test(edition: &str) {
    let rustc = bundled_rustc();
    if !rustc.exists() {
        eprintln!(
            "skipping macro_edition_compat::{}: bundled rustc not found at {}",
            edition,
            rustc.display()
        );
        return;
    }
    let sysroot = bundled_sysroot();

    let tmp = std::env::temp_dir().join(format!("cdp-macro-edition-{}", edition));
    std::fs::create_dir_all(&tmp).expect("mkdir tmp");

    let rlib_src = repo_root().join("rust/conjuredsp-rs/src/lib.rs");
    let rlib_out = tmp.join("libconjuredsp.rlib");
    assert!(
        build_rlib(&rustc, &sysroot, edition, &rlib_src, &rlib_out),
        "rlib failed to build at edition {edition}"
    );

    let fixture_src = tmp.join("fixture.rs");
    std::fs::write(&fixture_src, FIXTURE).expect("write fixture");
    let fixture_out = tmp.join("fixture.wasm");
    assert!(
        build_fixture(&rustc, &sysroot, edition, &rlib_out, &fixture_src, &fixture_out),
        "fixture failed to build at edition {edition}"
    );

    // Sanity-check the output: WASM magic bytes 00 61 73 6D.
    let bytes = std::fs::read(&fixture_out).expect("read fixture.wasm");
    assert!(
        bytes.len() > 8
            && bytes[0] == 0x00
            && bytes[1] == 0x61
            && bytes[2] == 0x73
            && bytes[3] == 0x6D,
        "fixture.wasm missing WASM magic for edition {edition}"
    );
}

#[test]
fn macros_compile_under_edition_2021() {
    run_compat_test("2021");
}

#[test]
fn macros_compile_under_edition_2024() {
    run_compat_test("2024");
}
