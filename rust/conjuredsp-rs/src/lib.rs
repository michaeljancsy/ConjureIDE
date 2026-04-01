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
//!     channels: i32, frame_count: i32, sample_rate: f32,
//! ) {
//!     let ctx = ctx(input, output, channels, frame_count, sample_rate);
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
pub use context::Context;
pub use dsp::*;
pub use filters::{Biquad, BiquadCoeffs};
pub use osc::{advance_phase, saw, sine, triangle, Lfo, Waveform};
pub use params::{param, ParamSpec};

// Re-export param builders (these are functions, not macros)
pub use params::{choice, db, freq, mix, pct, ratio, time_ms, toggle};

// Re-export JSON builder for macro use
pub use json::{write_param_json, JsonBuf};

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

        /// Create a [`conjuredsp::Context`] for safe buffer access.
        #[inline]
        #[allow(dead_code)]
        fn ctx(
            input: *const f32,
            output: *mut f32,
            channels: i32,
            frame_count: i32,
            sample_rate: f32,
        ) -> conjuredsp::Context {
            unsafe {
                conjuredsp::Context::new(
                    input,
                    output,
                    channels,
                    frame_count,
                    sample_rate,
                    PARAMS_BUF.as_ptr(),
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
/// Expands to:
/// - `NAM_MODEL` static holding the loaded model
/// - `NAM_DATA_BUF` static buffer for host data injection (4MB)
/// - `NAM_IN` / `NAM_OUT` static audio buffers
/// - WASM exports: `get_nam_data_ptr`, `init_nam`, `get_nam_active`
/// - Path metadata exports: `get_nam_path_ptr`, `get_nam_path_len`
///
/// # Example
///
/// ```ignore
/// use conjuredsp::*;
/// setup!();
/// nam!("tone3000://abc123/def456");
/// ```
#[macro_export]
macro_rules! nam {
    ($path:expr) => {
        static mut NAM_MODEL: Option<conjuredsp::NamModel> = None;
        static mut NAM_DATA_BUF: [u8; 4_194_304] = [0u8; 4_194_304];
        static mut NAM_IN: [f32; MAX_FR] = [0.0; MAX_FR];
        static mut NAM_OUT: [f32; MAX_FR] = [0.0; MAX_FR];

        static NAM_PATH: &str = $path;

        #[no_mangle]
        pub extern "C" fn get_nam_data_ptr() -> i32 {
            unsafe { NAM_DATA_BUF.as_ptr() as i32 }
        }

        #[no_mangle]
        pub extern "C" fn init_nam(data_len: i32) -> i32 {
            unsafe {
                match conjuredsp::NamModel::from_binary(&NAM_DATA_BUF[..data_len as usize]) {
                    Some(model) => { NAM_MODEL = Some(model); 1 }
                    None => 0
                }
            }
        }

        #[no_mangle]
        pub extern "C" fn get_nam_active() -> i32 {
            unsafe { if NAM_MODEL.is_some() { 1 } else { 0 } }
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
