//! ConjureDSP — Rust DSP building blocks for WASM presets.
//!
//! Provides macros to eliminate boilerplate and DSP primitives
//! mirroring the Python `conjuredsp` package.
//!
//! # Quick start
//!
//! ```ignore
//! use conjuredsp::*;
//! setup!();
//!
//! params! {
//!     CUTOFF = freq(),
//!     RESONANCE = param(0.0, 1.0).default(0.5),
//! }
//!
//! #[no_mangle]
//! pub extern "C" fn process(
//!     input: *const f32, output: *mut f32,
//!     channel_count: i32, frame_count: i32, sample_rate: f32,
//! ) {
//!     let ctx = ctx(input, output, channel_count, frame_count, sample_rate);
//!     for c in 0..ctx.channels() {
//!         for i in 0..ctx.frames() {
//!             ctx.set_output(c, i, ctx.input(c, i));
//!         }
//!     }
//! }
//! ```

pub mod accel;
pub mod buffers;
pub mod context;
pub mod dsp;
pub mod filters;
pub mod json;
pub mod nam;
pub mod osc;
pub mod params;

// Re-export everything at crate root for `use conjuredsp::*;`
pub use buffers::DelayLine;
pub use context::{Context, TELEMETRY_LEN};
pub use dsp::*;
pub use filters::{Biquad, BiquadCoeffs};
pub use osc::{advance_phase, saw, sine, triangle, Lfo, Waveform};
pub use params::{param, ParamSpec, TelemetryShape, TelemetrySpec};

// Re-export param builders (these are functions, not macros)
pub use params::{
    choice, db, freq, integer, mix, pct, ratio, scalar_telemetry, time_ms, toggle,
    vector_telemetry,
};

/// Maximum frames per render block. Covers Logic, Ableton, Reaper,
/// and Pro Tools (incl. HDX). Mirrored as `MAX_FR` in `setup!()` and
/// drives vector-telemetry slot length.
pub const MAX_FRAMES: usize = 4096;

// Re-export JSON builders for macro use
pub use json::{write_param_json, write_telemetry_json, JsonBuf};

// NAM (Neural Amp Modeler) inference
pub use nam::NamModel;

/// Declares all required WASM buffers, exports, and the `ctx()` helper.
///
/// Expands to:
/// - `INPUT_BUF`, `OUTPUT_BUF`, `PARAMS_BUF`, `TRANSPORT_BUF` static arrays
/// - `MAX_CH`, `MAX_FR` constants
/// - `T_TEMPO` .. `T_SAMPLE_POS` transport field indices
/// - `get_input_ptr()`, `get_output_ptr()`, `get_params_ptr()`, `get_transport_ptr()` exports
/// - `ctx()` helper function that creates a [`Context`]
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

        const T_TEMPO: usize = 0;
        const T_BEAT: usize = 1;
        const T_PLAYING: usize = 2;
        const T_TIME_SIG_NUM: usize = 3;
        const T_TIME_SIG_DEN: usize = 4;
        const T_SAMPLE_POS: usize = 5;

        #[no_mangle]
        pub extern "C" fn get_input_ptr() -> i32 {
            unsafe { INPUT_BUF.as_ptr() as i32 }
        }

        #[no_mangle]
        pub extern "C" fn get_output_ptr() -> i32 {
            unsafe { OUTPUT_BUF.as_ptr() as i32 }
        }

        #[no_mangle]
        pub extern "C" fn get_params_ptr() -> i32 {
            unsafe { PARAMS_BUF.as_ptr() as i32 }
        }

        #[no_mangle]
        pub extern "C" fn get_transport_ptr() -> i32 {
            unsafe { TRANSPORT_BUF.as_ptr() as i32 }
        }

        #[no_mangle]
        pub extern "C" fn get_telemetry_buf_ptr() -> i32 {
            unsafe { TELEMETRY_BUF.as_ptr() as i32 }
        }

        #[no_mangle]
        pub extern "C" fn get_telemetry_buf_len() -> i32 {
            unsafe { TELEMETRY_BUF.len() as i32 }
        }

        /// Create a [`conjuredsp::Context`] for safe buffer access.
        ///
        /// Argument order matches the host's `process()` calling
        /// convention: `(input, output, channel_count, frame_count,
        /// sample_rate)`. Pass your `process()` parameters through in
        /// the same positions and order.
        #[inline]
        #[allow(dead_code)]
        fn ctx(
            input: *const f32,
            output: *mut f32,
            channel_count: i32,
            frame_count: i32,
            sample_rate: f32,
        ) -> conjuredsp::Context {
            unsafe {
                conjuredsp::Context::new(
                    input,
                    output,
                    channel_count,
                    frame_count,
                    sample_rate,
                    PARAMS_BUF.as_ptr(),
                    TELEMETRY_BUF.as_mut_ptr(),
                )
            }
        }
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

        #[no_mangle]
        pub extern "C" fn get_param_metadata_ptr() -> i32 {
            METADATA.as_ptr() as i32
        }

        #[no_mangle]
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
/// ```ignore
/// use conjuredsp::*;
/// setup!();
/// params! { THRESHOLD = db().min(-60.0).max(0.0).default(-20.0) }
/// telemetry! {
///     ENV_LEVEL = scalar_telemetry(),               // unitless 0..1
///     GR_DB     = scalar_telemetry().unit("dB"),    // formatted as "-3.2 dB"
/// }
///
/// // Inside process():
/// ctx.set_telemetry_scalar(ENV_LEVEL, env);
/// ctx.set_telemetry_scalar(GR_DB, gr_db);
/// ```
#[macro_export]
macro_rules! telemetry {
    ( $( $NAME:ident = $spec:expr ),* $(,)? ) => {
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

        #[no_mangle]
        pub extern "C" fn get_telemetry_metadata_ptr() -> i32 {
            TELEMETRY_METADATA.as_ptr() as i32
        }

        #[no_mangle]
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
        #[no_mangle]
        pub extern "C" fn get_telemetry_vec_ptr(slot: i32) -> i32 {
            let s = slot as usize;
            if s >= TELEMETRY_SLOT_COUNT {
                return 0;
            }
            unsafe { TELEMETRY_VEC_BUFS[s].as_mut_ptr() as i32 }
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
                    core::ptr::copy_nonoverlapping(
                        samples.as_ptr(),
                        TELEMETRY_VEC_BUFS[slot].as_mut_ptr(),
                        len,
                    );
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
        #[no_mangle]
        pub extern "C" fn get_latency_samples() -> i32 {
            $samples as i32
        }
    };
}

/// Declares a NAM (Neural Amp Modeler) model to be loaded by the host.
///
/// NAM inference runs natively on the host side (not inside WASM) for
/// both correctness and performance. The WASM module calls a host import
/// (`__conjuredsp_nam_process`) that routes to a native `NamModel`.
///
/// Expands to:
/// - `NAM_IN` / `NAM_OUT` static audio buffers
/// - `nam_process()` helper that calls the host import
/// - Path metadata exports: `get_nam_path_ptr`, `get_nam_path_len`
///
/// # Example
///
/// ```ignore
/// use conjuredsp::*;
/// setup!();
/// nam!("tone3000://abc123/def456");
///
/// #[no_mangle]
/// pub extern "C" fn process(
///     input: *const f32, output: *mut f32,
///     channel_count: i32, frame_count: i32, sample_rate: f32,
/// ) {
///     let ctx = ctx(input, output, channel_count, frame_count, sample_rate);
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

        static NAM_PATH: &str = $path;

        extern "C" {
            fn __conjuredsp_nam_process(
                input_ptr: *const f32,
                output_ptr: *mut f32,
                frames: i32,
                channel: i32,
            ) -> i32;
        }

        /// Process audio through the host-side NAM model.
        /// Returns true if the model was active and processed successfully.
        #[inline]
        unsafe fn nam_process(input: &[f32], output: &mut [f32], channel: usize) -> bool {
            __conjuredsp_nam_process(
                input.as_ptr(),
                output.as_mut_ptr(),
                input.len() as i32,
                channel as i32,
            ) == 1
        }

        #[no_mangle]
        pub extern "C" fn get_nam_path_ptr() -> i32 {
            NAM_PATH.as_ptr() as i32
        }

        #[no_mangle]
        pub extern "C" fn get_nam_path_len() -> i32 {
            NAM_PATH.len() as i32
        }
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
