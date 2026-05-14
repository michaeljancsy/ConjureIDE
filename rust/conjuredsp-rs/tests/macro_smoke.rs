//! Composition smoke test for the post-#308 macro stack.
//!
//! The `lib.rs` macro `/// # Example` blocks for `telemetry!`, `nam!`,
//! `nams!`, and `state!` were all stale (they showed the legacy 5-arg
//! `extern "C" fn process(...)` shape and a standalone `setup!();`)
//! and weren't compile-checked because they're marked ```ignore`.
//! That's how the drift accumulated.
//!
//! This test exercises the macros that DON'T pull in host imports
//! (`process!`, `params!`, `persist!`, `persist_mut!`, `telemetry!`,
//! `state!`, `latency!`) paired together exactly as the rustdoc
//! examples teach. If the macros change shape in a way that breaks
//! composition, this file fails to compile.
//!
//! ## Why nam! and nams! aren't here
//!
//! Both declare `unsafe extern "C" { fn __conjuredsp_nam_process_slot(...) }`
//! — a host import resolved by the AU extension at WASM-instantiation
//! time. Cargo's host-target test build can't satisfy that link
//! without a stub, and stubbing the host signature is its own
//! drift hazard. The `nam!` / `nams!` shape stays locked by the
//! [`DocsDriftGuardTests`] Swift test (which reads `lib.rs` and asserts
//! the `///` example bodies don't carry the old 5-arg signature) and
//! by the export-AU end-to-end test, where a real NAM preset gets
//! compiled to WASM and instantiated.

use conjuredsp::*;

params! {
    GAIN = db().min(-24.0).max(12.0).default(0.0),
    MIX  = mix().default(0.5),
}

telemetry! {
    ENV_LEVEL = scalar_telemetry(),
    GR_DB     = scalar_telemetry().unit("dB"),
    SCOPE     = vector_telemetry(),
}

state!();

latency!(0);

persist!(ENVELOPE: f64 = 0.0);
persist!(WRITE_POS: usize = 0);
persist_mut!(SCRATCH: [[f32; MAX_FR]; MAX_CH] = [[0.0; MAX_FR]; MAX_CH]);

// Exercises the canonical post-#308 entry-point shape end-to-end:
//
//   process! { ctx => /* body */ }
//
// is the ONLY way user code declares the WASM `process` export. It
// internally invokes `setup!()`, so no standalone `setup!();` here
// (that would duplicate-define `INPUT_BUF` and refuse to compile —
// the exact failure mode the plan flags). The body composes every
// non-host-import macro from the modernization landing.
process! { ctx =>
    // Read parameters
    let gain_db = ctx.param(GAIN);
    let mix = ctx.param(MIX);

    // Scalar persist! state — Copy-type round-trip
    let mut env = ENVELOPE.get();

    // Scalar persist! state — counter (read-snapshot-mutate-writeback)
    WRITE_POS.set(WRITE_POS.get().wrapping_add(1));

    // Buffer-shaped persist_mut! state — in-place mutation
    SCRATCH.with_mut(|s| {
        for c in 0..ctx.channels() {
            for i in 0..ctx.frames() {
                let dry = ctx.input(c, i);
                s[c][i] = dry * gain_db * 0.01;  // arbitrary touch to keep s live
                let wet = s[c][i];
                ctx.set_output(c, i, dry * (1.0 - mix) + wet * mix);
                env = env * 0.95 + wet.abs() as f64 * 0.05;
            }
        }
    });

    ENVELOPE.set(env);

    // Telemetry — scalar + vector, both writable through Context
    ctx.set_telemetry_scalar(ENV_LEVEL, env as f32);
    ctx.set_telemetry_scalar(GR_DB, -3.0);

    // state! is exercised by reading the bundle-private state channel
    // (the macro is silent at module scope until the host writes bytes;
    // we only need it to compile composed with everything else).
    let _state_bytes: &[u8] = ctx.state_bytes();
    let _state_gen: u64 = ctx.state_generation();
}

#[test]
fn macros_compose_and_emit_expected_exports() {
    // The whole point of this test file is the `process! { ctx => ... }`
    // block above — if the macros silently broke composition (e.g.
    // `process!` stopped invoking `setup!()` internally, or `state!`
    // started colliding with `setup!()` statics), this file would have
    // failed to compile and we'd never have reached this assert.
    //
    // The runtime check is just a sanity floor: process() exists as a
    // symbol and can be called. The body of process() reads from
    // BLOCK_INFO_BUF (zeroed at module init) which means it iterates
    // zero channels / zero frames and exits cleanly.
    unsafe extern "C" {
        fn process();
    }
    unsafe { process(); }
}

#[test]
fn latency_macro_export_emitted() {
    // The `latency!(0)` invocation above emits `get_latency_samples`
    // as a `#[unsafe(no_mangle)] pub extern "C" fn`. On host, we can
    // call it directly.
    unsafe extern "C" {
        fn get_latency_samples() -> i32;
    }
    let n = unsafe { get_latency_samples() };
    assert_eq!(n, 0, "latency!(0) should report zero samples");
}

#[test]
fn params_metadata_export_contains_declared_names() {
    // params!() emits a METADATA static + `get_param_metadata_*`
    // exports. Inspect the static directly (the i32-typed pointer
    // export truncates on 64-bit native — same caveat as
    // tests/vector_telemetry.rs). The macro humanizes the const
    // identifier for the JSON `name` field (GAIN → "Gain") so the
    // DAW shows a friendly label.
    let s: &str = METADATA;
    assert!(s.contains(r#""name":"Gain""#), "Gain (from GAIN) missing in {s}");
    assert!(s.contains(r#""name":"Mix""#),  "Mix (from MIX) missing in {s}");
}

#[test]
fn telemetry_metadata_export_contains_declared_slots() {
    let s: &str = TELEMETRY_METADATA;
    assert!(s.contains(r#""name":"ENV_LEVEL""#), "ENV_LEVEL missing");
    assert!(s.contains(r#""name":"GR_DB""#),     "GR_DB missing");
    assert!(s.contains(r#""name":"SCOPE""#),     "SCOPE missing");
    assert!(s.contains(r#""shape":"vector""#),   "vector shape missing");
}
