//! ConjureDSP — Rust DSP building blocks for WASM presets.
//!
//! Provides macros to eliminate boilerplate and DSP primitives
//! mirroring the Python `conjuredsp` package.
//!
//! # Quick start
//!
//! ```ignore
//! use conjuredsp::*;
//!
//! params! {
//!     CUTOFF = freq(),
//!     RESONANCE = param(0.0, 1.0).default(0.5),
//! }
//!
//! // Per-block state lives in `persist!` (scalars + Copy coefficient
//! // structs recomputed on param change) or `persist_mut!` (DSP
//! // blocks mutated per sample — Biquad/Lfo/DelayLine — and raw
//! // buffers written linearly). Replaces `static mut`.
//! persist!(ENVELOPE: f64 = 0.0);
//!
//! process! { ctx =>
//!     let mut env = ENVELOPE.get();
//!     for c in 0..ctx.channels() {
//!         for i in 0..ctx.frames() {
//!             let s = ctx.input(c, i);
//!             env = 0.99 * env + 0.01 * (s.abs() as f64);
//!             ctx.set_output(c, i, s);
//!         }
//!     }
//!     ENVELOPE.set(env);
//! }
//! ```
//!
//! The `process!` macro subsumes `setup!()` (buffers, exports), reads
//! per-block scalars from a shared `BLOCK_INFO_BUF`, and emits the
//! zero-arg `extern "C" fn process()` the host calls. Do not hand-roll
//! an `extern "C" fn process(...)` — the host looks up a zero-arg
//! `process` export and the legacy 5-arg shape fails to load.

pub mod abi;
pub mod accel;
pub mod buffers;
pub mod context;
pub mod dsp;
pub mod filters;
pub mod json;
pub mod nam;
pub mod osc;
pub mod params;
pub mod persist;
pub mod state_json;

// Re-export everything at crate root for `use conjuredsp::*;`
pub use abi::BlockInfo;
pub use buffers::DelayLine;
pub use context::{Context, TELEMETRY_LEN};
pub use persist::{Persist, PersistMut};
pub use dsp::*;
pub use filters::{Biquad, BiquadCoeffs};
pub use osc::{advance_phase, saw, sine, triangle, Lfo, Waveform};
pub use params::{param, ParamSpec, TelemetryShape, TelemetrySpec};

// Re-export param builders (these are functions, not macros)
pub use params::{
    choice, db, freq, integer, lfo_rate, mix, pct, ratio, scalar_telemetry, time_ms, toggle,
    vector_telemetry,
};

/// Maximum frames per render block. Covers Logic, Ableton, Reaper,
/// and Pro Tools (incl. HDX). Mirrored as `MAX_FR` in `setup!()` and
/// drives vector-telemetry slot length.
pub const MAX_FRAMES: usize = 4096;

/// Maximum channels the sidechain input bus is sized for in
/// `setup!()`'s `SIDECHAIN_BUF`. Mirrored as `MAX_CH` in the macro.
/// Used by `Context::sidechain` to bounds-check the channel index so
/// scripts can't read past the buffer even with out-of-range input.
pub const MAX_SIDECHAIN_CHANNELS: usize = 2;

// Re-export JSON builders for macro use
pub use json::{write_param_json, write_telemetry_json, JsonBuf};

// NAM (Neural Amp Modeler) inference
pub use nam::NamModel;

/// Declares all required WASM buffers, exports, and the `ctx()` helper.
///
/// Expands to:
/// - `INPUT_BUF`, `OUTPUT_BUF`, `PARAMS_BUF`, `TRANSPORT_BUF`, `SIDECHAIN_BUF` static arrays
/// - `MAX_CH`, `MAX_FR` constants
/// - `T_TEMPO` .. `T_SAMPLE_POS` transport field indices
/// - `get_input_ptr()`, `get_output_ptr()`, `get_params_ptr()`,
///   `get_transport_ptr()`, `get_sidechain_ptr()`,
///   `get_sidechain_state_ptr()` exports
/// - `ctx()` helper function that creates a [`Context`]
///
/// `SIDECHAIN_BUF` mirrors `INPUT_BUF`'s layout (`MAX_CH * MAX_FR`
/// f32s, channel-sequential). The host writes the second input bus
/// here when one is connected and zero-fills when nothing is routed —
/// scripts read via [`Context::sidechain`] / [`Context::sidechain_connected`]
/// without per-block branches.
#[macro_export]
macro_rules! setup {
    () => {
        const MAX_CH: usize = 2;
        const MAX_FR: usize = 4096;

        static mut INPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
        static mut OUTPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
        static mut PARAMS_BUF: [f32; 16] = [0.0; 16];
        static mut TRANSPORT_BUF: [f32; 6] = [0.0; 6];
        // Always allocated even when no telemetry is declared — 64 bytes,
        // and `Context::set_telemetry_scalar` is a no-op if the script
        // never writes. The host treats a missing `get_telemetry_metadata_*`
        // export as "no telemetry" and never reads from this buffer.
        static mut TELEMETRY_BUF: [f32; conjuredsp::TELEMETRY_LEN] =
            [0.0; conjuredsp::TELEMETRY_LEN];
        // Always allocated. Sidechain is opt-in at the script level
        // (read via `ctx.sidechain()` / `ctx.sidechain_connected()`),
        // but allocating here means the host can write into it
        // unconditionally for any preset built against this macro
        // version — old scripts ignore the data, new ones consume it.
        // ~32 KiB at MAX_CH=2 / MAX_FR=4096; negligible vs. NAM tones.
        static mut SIDECHAIN_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
        // [channel_count, connected (0/1)]. Host writes once per render
        // block before `process()`; script reads via
        // `Context::sidechain_connected`.
        static mut SIDECHAIN_STATE: [i32; 2] = [0; 2];
        // Per-block scalars (frame_count, channel_count, sample_rate)
        // written by the host before each `process()` call. The zero-arg
        // `process!()` macro (step 4 of the modernization plan) reads
        // them back from here so its caller can hold the C ABI stable
        // even as new channels appear. The legacy 5-arg signature
        // ignores this buffer.
        static mut BLOCK_INFO_BUF: $crate::BlockInfo = $crate::BlockInfo::zeroed();

        const T_TEMPO: usize = 0;
        const T_BEAT: usize = 1;
        const T_PLAYING: usize = 2;
        const T_TIME_SIG_NUM: usize = 3;
        const T_TIME_SIG_DEN: usize = 4;
        const T_SAMPLE_POS: usize = 5;

        #[unsafe(no_mangle)]
        pub extern "C" fn get_input_ptr() -> i32 {
            &raw const INPUT_BUF as *const f32 as i32
        }

        #[unsafe(no_mangle)]
        pub extern "C" fn get_output_ptr() -> i32 {
            &raw mut OUTPUT_BUF as *mut f32 as i32
        }

        #[unsafe(no_mangle)]
        pub extern "C" fn get_params_ptr() -> i32 {
            &raw const PARAMS_BUF as *const f32 as i32
        }

        #[unsafe(no_mangle)]
        pub extern "C" fn get_transport_ptr() -> i32 {
            &raw const TRANSPORT_BUF as *const f32 as i32
        }

        #[unsafe(no_mangle)]
        pub extern "C" fn get_telemetry_buf_ptr() -> i32 {
            &raw const TELEMETRY_BUF as *const f32 as i32
        }

        #[unsafe(no_mangle)]
        pub extern "C" fn get_telemetry_buf_len() -> i32 {
            conjuredsp::TELEMETRY_LEN as i32
        }

        #[unsafe(no_mangle)]
        pub extern "C" fn get_sidechain_ptr() -> i32 {
            &raw const SIDECHAIN_BUF as *const f32 as i32
        }

        #[unsafe(no_mangle)]
        pub extern "C" fn get_sidechain_buf_len() -> i32 {
            // Bytes, mirroring `get_telemetry_buf_len`. Host derives
            // MAX_CH from this value (`bytes / 4 / MAX_FR`).
            (MAX_CH * MAX_FR * core::mem::size_of::<f32>()) as i32
        }

        #[unsafe(no_mangle)]
        pub extern "C" fn get_sidechain_state_ptr() -> i32 {
            &raw const SIDECHAIN_STATE as *const i32 as i32
        }

        #[unsafe(no_mangle)]
        pub extern "C" fn get_block_info_ptr() -> i32 {
            &raw const BLOCK_INFO_BUF as *const $crate::BlockInfo as i32
        }

        // Legacy 5-arg ctx() helper was removed when the zero-arg
        // process! macro landed — process!() constructs the Context
        // directly from BLOCK_INFO_BUF and the static buffer addresses.
        // Anything reaching for ctx() today is on the old shape and
        // should migrate to process! { ctx => /* body */ }.
    };
}

/// Declares parameter metadata and index constants.
///
/// Generates:
/// - `const NAME: usize = N;` for each parameter (sequential indices)
/// - `METADATA` static string with JSON array of parameter specs
/// - `get_param_metadata_ptr()` and `get_param_metadata_len()` WASM exports
///
/// # Example
///
/// ```ignore
/// params! {
///     CUTOFF = freq(),
///     RATIO = param(2.0, 20.0).unit(":1").default(4.0),
///     ATTACK = time_ms().min(0.5).max(50.0).default(5.0),
/// }
/// ```
#[macro_export]
macro_rules! params {
    ( $( $NAME:ident = $spec:expr ),* $(,)? ) => {
        // Generate sequential index constants
        conjuredsp::_params_indices!(0usize; $( $NAME ),*);

        // Build metadata JSON at compile time
        static METADATA: &str = {
            const SPECS: &[(& str, conjuredsp::ParamSpec)] = &[
                $( (stringify!($NAME), $spec) ),*
            ];

            const BUF: conjuredsp::JsonBuf = {
                let mut buf = conjuredsp::JsonBuf::new();
                buf = buf.push_byte(b'[');
                let mut i = 0;
                while i < SPECS.len() {
                    if i > 0 {
                        buf = buf.push_byte(b',');
                    }
                    buf = conjuredsp::write_param_json(buf, SPECS[i].0, &SPECS[i].1);
                    i += 1;
                }
                buf = buf.push_byte(b']');
                buf
            };

            // SAFETY: The JsonBuf only writes valid ASCII/UTF-8 bytes
            const BYTES: &[u8] = BUF.as_bytes();
            unsafe { core::str::from_utf8_unchecked(BYTES) }
        };

        #[unsafe(no_mangle)]
        pub extern "C" fn get_param_metadata_ptr() -> i32 {
            METADATA.as_ptr() as i32
        }

        #[unsafe(no_mangle)]
        pub extern "C" fn get_param_metadata_len() -> i32 {
            METADATA.len() as i32
        }
    };
}

/// Declares telemetry slot metadata and index constants.
///
/// Telemetry is the read-back twin of `params!()`: the DSP publishes
/// internal state (envelope follower output, computed gain reduction,
/// sidechain RMS, NAM model magnitude…) once per render block via
/// [`Context::set_telemetry_scalar`], and the host UI reads it from
/// the `audio.onFrame` payload's `telemetry` field.
///
/// Generates:
/// - `const NAME: usize = N;` for each slot (sequential indices, 0-based)
/// - `TELEMETRY_METADATA` static string with JSON `[{name, unit, shape}, …]`
/// - `get_telemetry_metadata_ptr()` and `get_telemetry_metadata_len()` WASM exports
///
/// The buffer itself is allocated by [`setup!`] regardless of whether
/// `telemetry!` is used. When this macro is omitted, the host treats
/// the missing metadata exports as "no telemetry" and never reads the
/// buffer — opt-in with zero overhead for scripts that don't need it.
///
/// # Example
///
/// `process!` invokes `setup!()` internally — do NOT write `setup!();`
/// alongside `process!` (you'll get a duplicate-static error). This
/// example is also exercised in `tests/macro_smoke.rs`.
///
/// ```ignore
/// use conjuredsp::*;
/// params! { THRESHOLD = db().min(-60.0).max(0.0).default(-20.0) }
/// telemetry! {
///     ENV_LEVEL = scalar_telemetry(),               // unitless 0..1
///     GR_DB     = scalar_telemetry().unit("dB"),    // formatted as "-3.2 dB"
/// }
///
/// process! { ctx =>
///     let env: f32 = 0.5; // …envelope follower output…
///     let gr_db: f32 = -3.2;
///     ctx.set_telemetry_scalar(ENV_LEVEL, env);
///     ctx.set_telemetry_scalar(GR_DB, gr_db);
/// }
/// ```
#[macro_export]
macro_rules! telemetry {
    () => {};
    ( $(,)? ) => {};
    ( $( $NAME:ident = $spec:expr ),+ $(,)? ) => {
        // Generate sequential index constants (independent of params).
        conjuredsp::_params_indices!(0usize; $( $NAME ),*);

        const TELEMETRY_SLOT_COUNT: usize =
            [$( stringify!($NAME) ),*].len();

        const TELEMETRY_SPECS: &[(&'static str, conjuredsp::TelemetrySpec)] = &[
            $( (stringify!($NAME), $spec) ),*
        ];

        // Build metadata JSON at compile time, mirroring `params!()`.
        static TELEMETRY_METADATA: &str = {
            const BUF: conjuredsp::JsonBuf = {
                let mut buf = conjuredsp::JsonBuf::new();
                buf = buf.push_byte(b'[');
                let mut i = 0;
                while i < TELEMETRY_SPECS.len() {
                    if i > 0 {
                        buf = buf.push_byte(b',');
                    }
                    buf = conjuredsp::write_telemetry_json(
                        buf,
                        TELEMETRY_SPECS[i].0,
                        &TELEMETRY_SPECS[i].1,
                    );
                    i += 1;
                }
                buf = buf.push_byte(b']');
                buf
            };

            // SAFETY: JsonBuf only writes valid ASCII/UTF-8 bytes.
            const BYTES: &[u8] = BUF.as_bytes();
            unsafe { core::str::from_utf8_unchecked(BYTES) }
        };

        // Per-slot vector telemetry buffers, one f32 per audio frame
        // up to MAX_FRAMES. Sized once for every declared slot —
        // scalar slots' rows are dead weight in WASM linear memory but
        // cost nothing at runtime (host never calls
        // `get_telemetry_vec_ptr` for slots whose metadata says
        // `shape: "scalar"`). The host harvests the per-block prefix
        // (length = current frame_count) into its own AtomicU32 ring
        // post-process.
        static mut TELEMETRY_VEC_BUFS:
            [[f32; conjuredsp::MAX_FRAMES]; TELEMETRY_SLOT_COUNT] =
            [[0.0_f32; conjuredsp::MAX_FRAMES]; TELEMETRY_SLOT_COUNT];

        #[unsafe(no_mangle)]
        pub extern "C" fn get_telemetry_metadata_ptr() -> i32 {
            TELEMETRY_METADATA.as_ptr() as i32
        }

        #[unsafe(no_mangle)]
        pub extern "C" fn get_telemetry_metadata_len() -> i32 {
            TELEMETRY_METADATA.len() as i32
        }

        /// Returns a WASM linear-memory pointer to the script-side
        /// vector telemetry buffer for `slot`. Host calls this once
        /// per declared vector slot per render block (skipped for
        /// scalar slots — host knows the shape from metadata).
        ///
        /// Returns 0 (null) for out-of-range indices. The buffer is
        /// `MAX_FRAMES` f32s long; the host reads exactly the current
        /// `frame_count` from the prefix.
        #[unsafe(no_mangle)]
        pub extern "C" fn get_telemetry_vec_ptr(slot: i32) -> i32 {
            let s = slot as usize;
            if s >= TELEMETRY_SLOT_COUNT {
                return 0;
            }
            // Per-slot row of the 2D array. `&raw mut TELEMETRY_VEC_BUFS`
            // is `*mut [[f32; MAX_FRAMES]; SLOT_COUNT]`; index the row
            // with .add(s) on the f32-cast base pointer.
            unsafe {
                (&raw mut TELEMETRY_VEC_BUFS as *mut f32)
                    .add(s * conjuredsp::MAX_FRAMES) as i32
            }
        }

        /// Local extension trait that adds `set_telemetry_vector` to
        /// `Context`. Defined inside the macro expansion so it's in
        /// scope at the script's `process()` site without an extra
        /// `use`. Couldn't live on `Context` itself: the per-slot
        /// buffers are emitted by this macro into the script's crate,
        /// not the conjuredsp crate.
        #[allow(non_camel_case_types)]
        trait __CdpTelemetryVectorExt {
            fn set_telemetry_vector(&self, slot: usize, samples: &[f32]);
        }

        impl __CdpTelemetryVectorExt for conjuredsp::Context {
            #[inline]
            fn set_telemetry_vector(&self, slot: usize, samples: &[f32]) {
                if slot >= TELEMETRY_SLOT_COUNT {
                    return;
                }
                // Silently no-op for scalar slots — matches the
                // out-of-range precedent and keeps the call site safe
                // when authors swap a slot's shape during iteration.
                if !matches!(
                    TELEMETRY_SPECS[slot].1.shape,
                    conjuredsp::TelemetryShape::Vector
                ) {
                    return;
                }
                let len = samples.len().min(conjuredsp::MAX_FRAMES);
                unsafe {
                    let dst = (&raw mut TELEMETRY_VEC_BUFS as *mut f32)
                        .add(slot * conjuredsp::MAX_FRAMES);
                    core::ptr::copy_nonoverlapping(samples.as_ptr(), dst, len);
                }
            }
        }
    };
}

/// Declares algorithmic latency in samples for DAW delay compensation.
///
/// Generates a `get_latency_samples() -> i32` WASM export that the host
/// reads at load time and reports via `AUAudioUnit.latency`.
///
/// Use this for lookahead processing, FFT windowing, oversampling, or any
/// algorithm that delays the output relative to the input. Do NOT use for
/// creative delay effects (delay lines, chorus, reverb) — those are
/// intentional and should not be compensated by the DAW.
///
/// # Example
///
/// ```ignore
/// latency!(256);  // 256 samples of lookahead
/// ```
#[macro_export]
macro_rules! latency {
    ($samples:expr) => {
        #[unsafe(no_mangle)]
        pub extern "C" fn get_latency_samples() -> i32 {
            $samples as i32
        }
    };
}

/// Declares a single NAM (Neural Amp Modeler) model to be loaded by the host.
///
/// For multiple models in the same preset, use [`nams!`] instead.
///
/// NAM inference runs natively on the host side (not inside WASM) for
/// both correctness and performance. The WASM module calls a host import
/// (`__conjuredsp_nam_process_slot`) that routes to a native `NamModel`.
///
/// Expands to:
/// - `NAM_IN` / `NAM_OUT` static audio buffers
/// - `nam_process()` helper that calls the host import
/// - Manifest exports: `get_nam_manifest_ptr`, `get_nam_manifest_len`
///
/// # Example
///
/// `process!` invokes `setup!()` internally, so don't write `setup!();`
/// alongside it. The macro-emitted `NAM_IN` / `NAM_OUT` scratch buffers
/// are accessed inside an `unsafe { … }` block — that's the macro's
/// contract, not the deprecated `static mut` user-state idiom. This
/// example is also exercised in `tests/macro_smoke.rs`.
///
/// ```ignore
/// use conjuredsp::*;
/// nam!("tone3000://abc123/def456");
///
/// process! { ctx =>
///     unsafe {
///         for c in 0..ctx.channels() {
///             let n = ctx.frames();
///             for i in 0..n { NAM_IN[i] = ctx.input(c, i); }
///             nam_process(&NAM_IN[..n], &mut NAM_OUT[..n], c);
///             for i in 0..n { ctx.set_output(c, i, NAM_OUT[i]); }
///         }
///     }
/// }
/// ```
#[macro_export]
macro_rules! nam {
    ($path:expr) => {
        static mut NAM_IN: [f32; MAX_FR] = [0.0; MAX_FR];
        static mut NAM_OUT: [f32; MAX_FR] = [0.0; MAX_FR];

        // Single-slot variant of the multi-slot manifest format used by `nams!`:
        // newline-separated paths, one per slot, in declaration order.
        static NAM_MANIFEST: &str = concat!($path, "\n");

        unsafe extern "C" {
            fn __conjuredsp_nam_process_slot(
                slot: u32,
                input_ptr: *const f32,
                output_ptr: *mut f32,
                frames: i32,
                channel: i32,
            ) -> i32;
        }

        /// Process audio through the host-side NAM model (single-slot).
        /// Returns true if the model was active and processed successfully.
        #[inline]
        #[allow(dead_code)]
        unsafe fn nam_process(input: &[f32], output: &mut [f32], channel: usize) -> bool {
            __conjuredsp_nam_process_slot(
                0,
                input.as_ptr(),
                output.as_mut_ptr(),
                input.len() as i32,
                channel as i32,
            ) == 1
        }

        #[unsafe(no_mangle)]
        pub extern "C" fn get_nam_manifest_ptr() -> i32 {
            NAM_MANIFEST.as_ptr() as i32
        }

        #[unsafe(no_mangle)]
        pub extern "C" fn get_nam_manifest_len() -> i32 {
            NAM_MANIFEST.len() as i32
        }
    };
}

/// Declares multiple named NAM model slots.
///
/// Each `NAME = "path"` pair becomes a `pub const NAME: u32 = <slot_index>`
/// and gets routed to its own injected NAM model on the host. Slot indices
/// are dense and assigned in declaration order.
///
/// Expands to:
/// - `pub const NAME: u32` per slot
/// - `NAM_MANIFEST: &str` — newline-separated paths, one per slot
/// - `extern "C" fn __conjuredsp_nam_process_slot` host import
/// - `nam_process_slot(slot, input, output, channel) -> bool` helper
/// - `get_nam_manifest_ptr` / `get_nam_manifest_len` exports
///
/// # Example
///
/// `process!` invokes `setup!()` internally. The `nam_process_slot`
/// call wraps a host import, so the call site needs `unsafe { … }` —
/// that's the macro's contract, not the deprecated user-state
/// `static mut` idiom. This example is also exercised in
/// `tests/macro_smoke.rs`.
///
/// ```ignore
/// use conjuredsp::*;
///
/// nams! {
///     DRIVE = "tone3000://19/56",
///     CAB   = "tone3000://42/8",
/// }
///
/// process! { ctx =>
///     let mut a = [0.0_f32; MAX_FR];
///     let mut b = [0.0_f32; MAX_FR];
///     unsafe {
///         for c in 0..ctx.channels() {
///             let n = ctx.frames();
///             for i in 0..n { a[i] = ctx.input(c, i); }
///             nam_process_slot(DRIVE, &a[..n], &mut b[..n], c);
///             nam_process_slot(CAB,   &b[..n], &mut a[..n], c);
///             for i in 0..n { ctx.set_output(c, i, a[i]); }
///         }
///     }
/// }
/// ```
#[macro_export]
macro_rules! nams {
    ( $( $NAME:ident = $path:expr ),+ $(,)? ) => {
        $crate::_nams_indices!(0u32; $( $NAME ),*);

        // Manifest: newline-separated paths, one per slot, in declaration order.
        // Host parses by splitting on '\n' and dropping empty trailing entries.
        static NAM_MANIFEST: &str = concat!( $( $path, "\n", )+ );

        unsafe extern "C" {
            fn __conjuredsp_nam_process_slot(
                slot: u32,
                input_ptr: *const f32,
                output_ptr: *mut f32,
                frames: i32,
                channel: i32,
            ) -> i32;
        }

        /// Process audio through the host-side NAM model in `slot`.
        /// Returns true if the slot's model was injected and processed successfully.
        #[inline]
        #[allow(dead_code)]
        unsafe fn nam_process_slot(
            slot: u32,
            input: &[f32],
            output: &mut [f32],
            channel: usize,
        ) -> bool {
            __conjuredsp_nam_process_slot(
                slot,
                input.as_ptr(),
                output.as_mut_ptr(),
                input.len() as i32,
                channel as i32,
            ) == 1
        }

        #[unsafe(no_mangle)]
        pub extern "C" fn get_nam_manifest_ptr() -> i32 {
            NAM_MANIFEST.as_ptr() as i32
        }

        #[unsafe(no_mangle)]
        pub extern "C" fn get_nam_manifest_len() -> i32 {
            NAM_MANIFEST.len() as i32
        }
    };
}

/// Internal helper: generates sequential `pub const SLOT: u32 = N` declarations.
#[macro_export]
#[doc(hidden)]
macro_rules! _nams_indices {
    ($idx:expr; ) => {};
    ($idx:expr; $NAME:ident $(, $REST:ident)*) => {
        #[allow(dead_code)]
        pub const $NAME: u32 = $idx;
        $crate::_nams_indices!($idx + 1u32; $( $REST ),*);
    };
}

/// Internal helper: generates sequential index constants.
#[macro_export]
#[doc(hidden)]
macro_rules! _params_indices {
    ($idx:expr; ) => {};
    ($idx:expr; $NAME:ident $(, $REST:ident)*) => {
        #[allow(dead_code)]
        const $NAME: usize = $idx;
        conjuredsp::_params_indices!($idx + 1usize; $( $REST ),*);
    };
}

/// Default per-script cap for the state buffer in bytes (matches the
/// host's `DEFAULT_STATE_CAP_BYTES`). Scripts can override via
/// `state!(T, max_bytes = N)`.
pub const DEFAULT_STATE_CAP_BYTES: usize = 65_536;

/// Header size at the start of `STATE_BUF`. Layout:
///   bytes [0..8]   — current state generation, little-endian u64
///   bytes [8..12]  — used length of the JSON content, little-endian u32
///   bytes [12..]   — JSON content (UTF-8 bytes)
///
/// Read by the script-side `state!()` macro to decide whether to
/// re-deserialize. Written by the host on every render block before
/// calling `process()`.
pub const STATE_HEADER_BYTES: usize = 12;

/// Declares the bundle-private state buffer for this preset and emits
/// the host-facing exports plus script-facing `cx.state_bytes()` /
/// `cx.state_generation()` accessors.
///
/// Forms:
/// - `state!();` — uses `DEFAULT_STATE_CAP_BYTES` (64 KiB) max content size.
/// - `state!(max_bytes = N);` — explicit cap up to 1 MiB. Script
///   author trades audio-thread parse latency for headroom.
///
/// Unlike Python's `STATE = {…}` (which is automatically parsed into a
/// `MappingProxyType` by the kernel), the Rust side hands the script
/// raw JSON bytes from `STATE_BUF`. The script chooses how to parse
/// them — either install a JSON crate via the crate package manager,
/// hand-roll a tiny parser for a known shape, or use a fixed-layout
/// binary format the script's UI agrees to write. The generation
/// counter lets the script cache its own parsed value across blocks
/// and only re-parse when the host has accepted a UI / MCP write.
///
/// Generates:
/// - `STATE_BUF: [u8; max_bytes + STATE_HEADER_BYTES]` static — the
///   shared buffer the host writes into.
/// - `get_state_buf_ptr()`, `get_state_buf_capacity()` exports — the
///   host's discovery handles for the buffer.
/// - Extension trait methods `Context::state_bytes() -> &[u8]` and
///   `Context::state_generation() -> u64` for reading the live content.
///
/// # Example
///
/// `process!` invokes `setup!()` internally. The identifier on the
/// left of `=>` becomes the `Context` binding — `cx` works as well as
/// `ctx`. This example is also exercised in `tests/macro_smoke.rs`.
///
/// ```ignore
/// use conjuredsp::*;
/// params! { /* ... */ }
/// state!();
///
/// process! { cx =>
///     let bytes: &[u8] = cx.state_bytes();
///     let gen: u64 = cx.state_generation();
///     // Cache parsed value yourself; re-parse only when gen changes.
/// }
/// ```
#[macro_export]
macro_rules! state {
    () => {
        $crate::state!(max_bytes = $crate::DEFAULT_STATE_CAP_BYTES);
    };
    (max_bytes = $cap:expr) => {
        const STATE_MAX_BYTES: usize = $cap;
        const STATE_BUF_TOTAL: usize = STATE_MAX_BYTES + $crate::STATE_HEADER_BYTES;

        static mut STATE_BUF: [u8; STATE_BUF_TOTAL] = {
            let mut buf = [0u8; STATE_BUF_TOTAL];
            buf[0] = 0xff;
            buf[1] = 0xff;
            buf[2] = 0xff;
            buf[3] = 0xff;
            buf[4] = 0xff;
            buf[5] = 0xff;
            buf[6] = 0xff;
            buf[7] = 0xff;
            buf
        };

        #[unsafe(no_mangle)]
        pub extern "C" fn get_state_buf_ptr() -> i32 {
            &raw const STATE_BUF as *const u8 as i32
        }

        #[unsafe(no_mangle)]
        pub extern "C" fn get_state_buf_capacity() -> i32 {
            STATE_BUF_TOTAL as i32
        }

        trait __CdpStateExt {
            fn state_bytes(&self) -> &'static [u8];
            fn state_generation(&self) -> u64;
            fn state_int(&self, key: &str) -> Option<i32>;
            fn state_int_or(&self, key: &str, default: i32) -> i32;
            fn state_bool(&self, key: &str) -> Option<bool>;
            fn state_bool_or(&self, key: &str, default: bool) -> bool;
            fn state_f32(&self, key: &str) -> Option<f32>;
            fn state_f32_or(&self, key: &str, default: f32) -> f32;
            fn state_array_u8<const N: usize>(&self, key: &str) -> Option<[u8; N]>;
            fn state_array_u8_or<const N: usize>(
                &self,
                key: &str,
                default: [u8; N],
            ) -> [u8; N];
            fn state_array_i32<const N: usize>(&self, key: &str) -> Option<[i32; N]>;
            fn state_array_i32_or<const N: usize>(
                &self,
                key: &str,
                default: [i32; N],
            ) -> [i32; N];
            fn state_array_f32<const N: usize>(&self, key: &str) -> Option<[f32; N]>;
            fn state_array_f32_or<const N: usize>(
                &self,
                key: &str,
                default: [f32; N],
            ) -> [f32; N];
        }

        impl __CdpStateExt for conjuredsp::Context {
            #[inline]
            fn state_bytes(&self) -> &'static [u8] {
                unsafe {
                    let buf_ptr = &raw const STATE_BUF as *const u8;
                    let mut len_bytes = [0u8; 4];
                    core::ptr::copy_nonoverlapping(
                        buf_ptr.add(8),
                        len_bytes.as_mut_ptr(),
                        4,
                    );
                    let used_len = u32::from_le_bytes(len_bytes) as usize;
                    let max_content =
                        STATE_BUF_TOTAL - $crate::STATE_HEADER_BYTES;
                    let n = used_len.min(max_content);
                    core::slice::from_raw_parts(
                        buf_ptr.add($crate::STATE_HEADER_BYTES),
                        n,
                    )
                }
            }

            #[inline]
            fn state_generation(&self) -> u64 {
                unsafe {
                    let buf_ptr = &raw const STATE_BUF as *const u8;
                    let mut gen_bytes = [0u8; 8];
                    core::ptr::copy_nonoverlapping(
                        buf_ptr,
                        gen_bytes.as_mut_ptr(),
                        8,
                    );
                    u64::from_le_bytes(gen_bytes)
                }
            }

            #[inline]
            fn state_int(&self, key: &str) -> Option<i32> {
                let bytes = self.state_bytes();
                let v = $crate::state_json::find_value(bytes, key)?;
                let n = $crate::state_json::parse_i64(v)?;
                i32::try_from(n).ok()
            }

            #[inline]
            fn state_int_or(&self, key: &str, default: i32) -> i32 {
                self.state_int(key).unwrap_or(default)
            }

            #[inline]
            fn state_bool(&self, key: &str) -> Option<bool> {
                let bytes = self.state_bytes();
                let v = $crate::state_json::find_value(bytes, key)?;
                $crate::state_json::parse_bool(v)
            }

            #[inline]
            fn state_bool_or(&self, key: &str, default: bool) -> bool {
                self.state_bool(key).unwrap_or(default)
            }

            #[inline]
            fn state_f32(&self, key: &str) -> Option<f32> {
                let bytes = self.state_bytes();
                let v = $crate::state_json::find_value(bytes, key)?;
                let n = $crate::state_json::parse_f64(v)?;
                let f = n as f32;
                if f.is_finite() {
                    Some(f)
                } else {
                    None
                }
            }

            #[inline]
            fn state_f32_or(&self, key: &str, default: f32) -> f32 {
                self.state_f32(key).unwrap_or(default)
            }

            #[inline]
            fn state_array_u8<const N: usize>(&self, key: &str) -> Option<[u8; N]> {
                let bytes = self.state_bytes();
                let v = $crate::state_json::find_value(bytes, key)?;
                let mut out = [0u8; N];
                let written = $crate::state_json::parse_array_into(
                    v,
                    &mut out,
                    $crate::state_json::decode_u8,
                )?;
                if written < N {
                    return None;
                }
                Some(out)
            }

            #[inline]
            fn state_array_u8_or<const N: usize>(
                &self,
                key: &str,
                default: [u8; N],
            ) -> [u8; N] {
                self.state_array_u8::<N>(key).unwrap_or(default)
            }

            #[inline]
            fn state_array_i32<const N: usize>(&self, key: &str) -> Option<[i32; N]> {
                let bytes = self.state_bytes();
                let v = $crate::state_json::find_value(bytes, key)?;
                let mut out = [0i32; N];
                let written = $crate::state_json::parse_array_into(
                    v,
                    &mut out,
                    $crate::state_json::decode_i32,
                )?;
                if written < N {
                    return None;
                }
                Some(out)
            }

            #[inline]
            fn state_array_i32_or<const N: usize>(
                &self,
                key: &str,
                default: [i32; N],
            ) -> [i32; N] {
                self.state_array_i32::<N>(key).unwrap_or(default)
            }

            #[inline]
            fn state_array_f32<const N: usize>(&self, key: &str) -> Option<[f32; N]> {
                let bytes = self.state_bytes();
                let v = $crate::state_json::find_value(bytes, key)?;
                let mut out = [0f32; N];
                let written = $crate::state_json::parse_array_into(
                    v,
                    &mut out,
                    $crate::state_json::decode_f32,
                )?;
                if written < N {
                    return None;
                }
                Some(out)
            }

            #[inline]
            fn state_array_f32_or<const N: usize>(
                &self,
                key: &str,
                default: [f32; N],
            ) -> [f32; N] {
                self.state_array_f32::<N>(key).unwrap_or(default)
            }
        }
    };
}

/// The DSP entry point — subsumes [`setup!`] and emits a zero-arg
/// `extern "C" fn process()`.
///
/// The host writes the per-block scalars (`frame_count`,
/// `channel_count`, `sample_rate`) into a shared `BLOCK_INFO_BUF`
/// before each call; `process!` reads them back to build a
/// [`Context`](crate::Context) bound to the user-named identifier on
/// the left of `=>`. The body that follows runs as the function body
/// of `process()`. Every preset's entry point becomes one line of
/// boilerplate (the `process!` invocation) instead of nine lines of
/// FFI plumbing.
///
/// # Why `ctx =>` instead of `|ctx|` (closure syntax)?
///
/// Both forms work hygienically — the user's chosen identifier is
/// captured in caller hygiene context. The `=>` form is chosen because
/// `|ctx|` pushes authors toward writing a real closure inside the
/// macro, and WASM debug-build backtraces render closures as
/// `process::{{closure}}::<hash>` synthetic names — harder to read in
/// panics and `os_log` traces. The `=>` form expands to a straight
/// `let ctx = …;` inside `extern "C" fn process()`, so the body's
/// stack frame stays just `process`.
///
/// # Example
///
/// ```ignore
/// use conjuredsp::*;
///
/// params! {
///     GAIN = db().min(-24.0).max(12.0).default(0.0),
///     MIX  = mix(),
/// }
///
/// process! { ctx =>
///     let gain = db_to_gain(ctx.param(GAIN));
///     let mix  = ctx.param(MIX);
///     for c in 0..ctx.channels() {
///         for i in 0..ctx.frames() {
///             let dry = ctx.input(c, i);
///             ctx.set_output(c, i, dry * gain * mix + dry * (1.0 - mix));
///         }
///     }
/// }
/// ```
///
/// # No backwards-compatibility shim
///
/// `process!` subsumes `setup!()` — do NOT write `setup!();` alongside
/// it (you'd get duplicate-static errors). The host calls the
/// zero-arg `process()` produced here; the legacy
/// `process(input, output, channel_count, frame_count, sample_rate)`
/// shape from before this macro is gone.
#[macro_export]
macro_rules! process {
    ( $ctx:ident => $($body:tt)* ) => {
        $crate::setup!();

        #[unsafe(no_mangle)]
        pub extern "C" fn process() {
            // SAFETY: WASM modules are single-threaded; INPUT_BUF /
            // OUTPUT_BUF / PARAMS_BUF / etc. are module-lifetime, never
            // dropped. The host writes BLOCK_INFO_BUF immediately
            // before this call and never concurrently with it.
            let block_info: $crate::BlockInfo = unsafe { *(&raw const BLOCK_INFO_BUF) };
            let $ctx: $crate::Context = unsafe {
                $crate::Context::new_with_sidechain(
                    &raw const INPUT_BUF as *const f32,
                    &raw mut OUTPUT_BUF as *mut f32,
                    block_info.channel_count as i32,
                    block_info.frame_count as i32,
                    block_info.sample_rate,
                    &raw const PARAMS_BUF as *const f32,
                    &raw mut TELEMETRY_BUF as *mut f32,
                    &raw const SIDECHAIN_BUF as *const f32,
                    &raw const SIDECHAIN_STATE as *const i32,
                )
            };
            $($body)*
        }
    };
    ( $($_:tt)* ) => {
        compile_error!(
            "process! requires a context binding.\n\
             Use: process! { ctx => /* body */ }\n\
             (or any identifier in place of `ctx`)."
        );
    };
}

/// Declares a persistent scalar (or `Copy` value) that survives across
/// render blocks. See [`Persist`](crate::Persist) for the access
/// pattern (`get` / `set` / `replace`).
///
/// Read/write happens without `unsafe { … }` from the caller's side.
///
/// # Example
///
/// ```ignore
/// use conjuredsp::*;
///
/// persist!(ENVELOPE: f64 = 0.0);
/// persist!(WRITE_POS: usize = 0);
///
/// // Inside process():
/// ENVELOPE.set(ENVELOPE.get() * 0.95 + sample.abs() as f64 * 0.05);
/// WRITE_POS.set(WRITE_POS.get().wrapping_add(1));
/// ```
#[macro_export]
macro_rules! persist {
    ($(#[$attr:meta])* $name:ident : $ty:ty = $init:expr) => {
        $(#[$attr])* static $name: $crate::Persist<$ty> = $crate::Persist::new($init);
    };
}

/// Declares persistent state mutated in place via
/// [`PersistMut::with_mut`](crate::PersistMut::with_mut).
///
/// Reach for `persist_mut!` when the value is mutated during the
/// render loop — either a DSP block whose `&mut self` methods
/// (`Biquad::process_sample`, `Lfo::tick`, `DelayLine::write`) are the
/// natural usage shape, or a raw buffer written linearly per block
/// (delay-line write-through, IR convolution scratch, scope rings).
/// The closure body gets `&mut T`, so methods run without a
/// read-modify-write round-trip through `get`/`set`.
///
/// The closure passed to `with_mut` must not call any other method on
/// the same `PersistMut` (debug builds panic on reentrant access;
/// see [`PersistMut`](crate::PersistMut) docs).
///
/// # Example
///
/// ```ignore
/// use conjuredsp::*;
///
/// persist_mut!(DELAYS: [DelayLine<48000>; 2] = [DelayLine::new(); 2]);
///
/// // Inside process():
/// DELAYS.with_mut(|d| {
///     d[channel].write(sample);
///     let y = d[channel].read(delay_samples);
/// });
/// ```
#[macro_export]
macro_rules! persist_mut {
    ($(#[$attr:meta])* $name:ident : $ty:ty = $init:expr) => {
        $(#[$attr])* static $name: $crate::PersistMut<$ty> = $crate::PersistMut::new($init);
    };
}
