// FFI entry points and the C-callable kernel surface are studded with
// `unsafe fn` bodies that perform raw pointer reads / writes. Edition
// 2024 promotes `unsafe_op_in_unsafe_fn` to a deny, which would force
// inner `unsafe { … }` blocks at every callsite (62 here, mechanical
// noise). Allow at the crate level instead — the entire surface
// already has its safety contract documented in the trailing `# Safety`
// section of each fn.
#![allow(unsafe_op_in_unsafe_fn)]

mod backend;
mod kernel;
mod license;
mod params;
mod passthrough_backend;
mod python_backend;
mod ring_buffer;
mod wasm_backend;

use kernel::DSPKernel;
use std::ffi::CStr;
use std::os::raw::c_char;
use std::sync::OnceLock;

/// Ensures CONJUREDSP_TONES_DIR is set exactly once, avoiding the POSIX
/// setenv() thread-safety issue when multiple AU instances init concurrently.
static TONES_DIR_INIT: OnceLock<()> = OnceLock::new();

/// Guards `install_panic_logger` so the hook installs exactly once even if
/// multiple AU instances each call `dsp_kernel_create`.
#[cfg(debug_assertions)]
static PANIC_HOOK_INSTALLED: OnceLock<()> = OnceLock::new();

/// Debug-only panic hook that writes the panic message + location +
/// backtrace to the App Group container before the default hook runs.
/// Behavior-neutral — does NOT catch the panic, so `extern "C"` boundaries
/// still abort. Purely diagnostic; the file is the only place the panic
/// message survives, since AU extension stderr isn't captured anywhere
/// readable.
///
/// Writes to `~/Library/Group Containers/group.com.MichaelJancsy.ConjureDSP/
/// rust-panic.log`. `/tmp` is sandbox-denied from the appex, so we use the
/// App Group container instead, which the appex has full read+write access
/// to via its `com.apple.security.application-groups` entitlement.
///
/// `cfg(debug_assertions)`-gated so it never ships in Release.
#[cfg(debug_assertions)]
fn install_panic_logger() {
    PANIC_HOOK_INSTALLED.get_or_init(|| {
        let default_hook = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            let mut msg = String::new();
            let ts = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs_f64())
                .unwrap_or(0.0);
            msg.push_str(&format!("[{ts:.3}] RUST PANIC\n"));
            if let Some(loc) = info.location() {
                msg.push_str(&format!(
                    "  location: {}:{}:{}\n",
                    loc.file(),
                    loc.line(),
                    loc.column()
                ));
            }
            msg.push_str(&format!("  payload: {info}\n"));
            msg.push_str(&format!(
                "  thread: {:?}\n",
                std::thread::current().name().unwrap_or("<unnamed>")
            ));
            let backtrace = std::backtrace::Backtrace::force_capture();
            msg.push_str(&format!("  backtrace:\n{backtrace}\n"));
            if let Ok(home) = std::env::var("HOME") {
                let path = format!(
                    "{home}/Library/Group Containers/group.com.MichaelJancsy.ConjureDSP/rust-panic.log"
                );
                let _ = std::fs::write(&path, &msg);
            }
            default_hook(info);
        }));
    });
}

#[cfg(not(debug_assertions))]
#[inline(always)]
fn install_panic_logger() {}

/// Opaque handle to the DSP kernel. Swift sees this as `OpaquePointer`.
pub type DSPKernelRef = *mut DSPKernel;

#[unsafe(no_mangle)]
pub extern "C" fn dsp_kernel_create() -> DSPKernelRef {
    install_panic_logger();
    Box::into_raw(Box::new(DSPKernel::new()))
}

/// # Safety
/// `kernel` must be a valid pointer returned by `dsp_kernel_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsp_kernel_destroy(kernel: DSPKernelRef) {
    if !kernel.is_null() {
        drop(Box::from_raw(kernel));
    }
}

/// # Safety
/// `kernel` must be a valid pointer returned by `dsp_kernel_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsp_kernel_initialize(
    kernel: DSPKernelRef,
    input_channel_count: i32,
    output_channel_count: i32,
    sample_rate: f64,
) {
    // Reject pathological sample rates (0, NaN, Inf, or outside any real-world
    // audio range) before they reach kernel math that divides by sample_rate.
    // Swift's allocateRenderResources may briefly pass 0 during DAW reconfiguration.
    if !sample_rate.is_finite() || sample_rate < 8_000.0 || sample_rate > 384_000.0 {
        eprintln!(
            "dsp_kernel_initialize: rejected invalid sample_rate={sample_rate}; \
             must be finite and in [8000, 384000]"
        );
        return;
    }
    (*kernel).initialize(input_channel_count, output_channel_count, sample_rate);
}

/// # Safety
/// `kernel` must be a valid pointer returned by `dsp_kernel_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsp_kernel_deinitialize(kernel: DSPKernelRef) {
    (*kernel).deinitialize();
}

/// # Safety
/// `kernel` must be a valid pointer returned by `dsp_kernel_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsp_kernel_set_bypassed(kernel: DSPKernelRef, bypass: bool) {
    (*kernel).set_bypassed(bypass);
}

/// Mark the start of a preset-load window. The audio thread ramps the output
/// to silence (5 ms fade-out) and holds silence — even after a backend swap —
/// until `dsp_kernel_end_preset_transition` is called. Idempotent.
///
/// Wrap every code path that mutates kernel parameters or stages a new backend
/// (`selectPreset`, `currentPreset` setter, MCP `save_preset`, `fullState`
/// restore, etc.) so the OLD backend can't be heard rendering audio with the
/// NEW preset's parameter values during the load window.
///
/// # Safety
/// `kernel` must be a valid pointer returned by `dsp_kernel_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsp_kernel_begin_preset_transition(kernel: DSPKernelRef) {
    (*kernel).begin_preset_transition();
}

/// Release the mute hold set by `dsp_kernel_begin_preset_transition`. The
/// audio thread observes the cleared flag on its next callback and ramps the
/// output back to full level via FADE_IN. Idempotent.
///
/// # Safety
/// `kernel` must be a valid pointer returned by `dsp_kernel_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsp_kernel_end_preset_transition(kernel: DSPKernelRef) {
    (*kernel).end_preset_transition();
}

/// Returns the current swap-state-machine phase
/// (0 = IDLE, 1 = FADE_OUT, 2 = FADE_IN). Diagnostic only — used by tests
/// to verify the kernel returned to IDLE after a preset transition.
///
/// # Safety
/// `kernel` must be a valid pointer returned by `dsp_kernel_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsp_kernel_swap_phase(kernel: DSPKernelRef) -> u8 {
    (*kernel).swap_phase()
}

/// # Safety
/// `kernel` must be a valid pointer returned by `dsp_kernel_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsp_kernel_is_bypassed(kernel: DSPKernelRef) -> bool {
    (*kernel).is_bypassed()
}

/// # Safety
/// `kernel` must be a valid pointer returned by `dsp_kernel_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsp_kernel_set_parameter(
    kernel: DSPKernelRef,
    address: u64,
    value: f32,
) {
    (*kernel).set_parameter(address, value);
}

/// # Safety
/// `kernel` must be a valid pointer returned by `dsp_kernel_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsp_kernel_get_parameter(kernel: DSPKernelRef, address: u64) -> f32 {
    (*kernel).get_parameter(address)
}

/// # Safety
/// `kernel` must be a valid pointer returned by `dsp_kernel_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsp_kernel_get_max_frames(kernel: DSPKernelRef) -> u32 {
    (*kernel).maximum_frames_to_render()
}

/// # Safety
/// `kernel` must be a valid pointer returned by `dsp_kernel_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsp_kernel_set_max_frames(kernel: DSPKernelRef, max_frames: u32) {
    (*kernel).set_maximum_frames_to_render(max_frames);
}

/// Process audio buffers. Called from the real-time audio thread.
///
/// # Safety
/// - `kernel` must be a valid pointer returned by `dsp_kernel_create`.
/// - `input_buffers` must point to `channel_count` valid `*const f32` pointers.
/// - `output_buffers` must point to `channel_count` valid `*mut f32` pointers.
/// - Each channel buffer must contain at least `frame_count` samples.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsp_kernel_process(
    kernel: DSPKernelRef,
    input_buffers: *const *const f32,
    output_buffers: *const *mut f32,
    channel_count: u32,
    frame_count: u32,
) {
    (*kernel).process(input_buffers, output_buffers, channel_count, frame_count);
}

/// Process audio with an optional sidechain input bus. Mirrors
/// `dsp_kernel_process` and adds three trailing arguments describing the
/// sidechain pull for this render block.
///
/// When `sidechain_connected` is false (or `sidechain_buffers` is null,
/// or `sidechain_channel_count` is zero), backends that consume sidechain
/// audio see silence. Old presets that don't read sidechain are
/// unaffected.
///
/// Both sides of the FFI ship together, so this is purely additive — the
/// legacy `dsp_kernel_process` entry point delegates to this one with no
/// sidechain so callers that haven't been updated still work.
///
/// # Safety
/// - `kernel` must be a valid pointer returned by `dsp_kernel_create`.
/// - `input_buffers` / `output_buffers` constraints from `dsp_kernel_process`
///   apply.
/// - When `sidechain_connected` is true and `sidechain_buffers` is non-null,
///   it must point to `sidechain_channel_count` valid `*const f32` pointers,
///   each with at least `frame_count` samples.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsp_kernel_process_with_sidechain(
    kernel: DSPKernelRef,
    input_buffers: *const *const f32,
    output_buffers: *const *mut f32,
    channel_count: u32,
    frame_count: u32,
    sidechain_buffers: *const *const f32,
    sidechain_channel_count: u32,
    sidechain_connected: bool,
) {
    (*kernel).process_with_sidechain(
        input_buffers,
        output_buffers,
        channel_count,
        frame_count,
        sidechain_buffers,
        sidechain_channel_count,
        sidechain_connected,
    );
}

/// Update host DAW transport state. Called from the real-time audio thread
/// once per render callback, before the process loop.
///
/// # Safety
/// - `kernel` must be a valid pointer returned by `dsp_kernel_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsp_kernel_set_transport(
    kernel: DSPKernelRef,
    tempo: f64,
    beat_position: f64,
    is_playing: bool,
    time_sig_numerator: i32,
    time_sig_denominator: i32,
    sample_position: f64,
) {
    (*kernel).set_transport(
        tempo,
        beat_position,
        is_playing,
        time_sig_numerator,
        time_sig_denominator,
        sample_position,
    );
}

/// Load a Python script for DSP processing.
///
/// `python_home` is the path to the bundled Python distribution root (containing lib/python3.14/).
/// `script_path` is the path to the .py file containing a `process()` function.
///
/// Returns true on success, false on error (errors are printed to stderr).
///
/// # Safety
/// - `kernel` must be a valid pointer returned by `dsp_kernel_create`.
/// - `python_home` and `script_path` must be valid null-terminated C strings.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsp_kernel_load_script(
    kernel: DSPKernelRef,
    python_home: *const c_char,
    script_path: *const c_char,
) -> bool {
    let python_home = match CStr::from_ptr(python_home).to_str() {
        Ok(s) => s,
        Err(_) => return false,
    };
    let script_path = match CStr::from_ptr(script_path).to_str() {
        Ok(s) => s,
        Err(_) => return false,
    };
    (*kernel).load_script(python_home, script_path)
}

/// Prepend a directory to Python's sys.path so user-installed packages are importable.
/// Idempotent — safe to call multiple times. Takes effect immediately.
/// Pass null to no-op.
///
/// # Safety
/// - `kernel` must be a valid pointer returned by `dsp_kernel_create`.
/// - `path` must be a valid null-terminated C string, or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsp_kernel_set_extra_site_packages(
    kernel: DSPKernelRef,
    path: *const c_char,
) {
    if !path.is_null() {
        if let Ok(s) = CStr::from_ptr(path).to_str() {
            let _ = (*kernel).set_extra_site_packages(s);
        }
    }
}

/// Set the directory where downloaded NAM tone files are stored.
/// This sets the `CONJUREDSP_TONES_DIR` environment variable so Python scripts
/// can resolve `tone3000://` paths via `conjuredsp.nam.load_model()`.
///
/// Call this once after kernel creation, before loading scripts.
/// Pass null to no-op.
///
/// # Safety
/// - `kernel` must be a valid pointer returned by `dsp_kernel_create`.
/// - `path` must be a valid null-terminated C string, or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsp_kernel_set_tones_dir(
    _kernel: DSPKernelRef,
    path: *const c_char,
) {
    if !path.is_null() {
        if let Ok(s) = CStr::from_ptr(path).to_str() {
            let owned = s.to_string();
            TONES_DIR_INIT.get_or_init(|| {
                // SAFETY: get_or_init guarantees this runs exactly once,
                // and dsp_kernel_set_tones_dir is called from the Swift
                // main thread before any pyo3 init or worker spawn —
                // no concurrent env mutation possible.
                unsafe {
                    std::env::set_var("CONJUREDSP_TONES_DIR", &owned);
                }
            });
        }
    }
}

/// Load a WASM module for DSP processing.
///
/// The module must export a `process` function with signature
/// `(input_ptr: i32, output_ptr: i32, channel_count: i32, frame_count: i32, sample_rate: f32)`
/// and a `memory` (linear memory).
///
/// Returns true on success, false on error (check `dsp_kernel_last_error`).
///
/// # Safety
/// - `kernel` must be a valid pointer returned by `dsp_kernel_create`.
/// - `wasm_bytes` must point to `len` valid bytes of a WASM module.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsp_kernel_load_wasm(
    kernel: DSPKernelRef,
    wasm_bytes: *const u8,
    len: u32,
) -> bool {
    if wasm_bytes.is_null() || len == 0 {
        return false;
    }
    let bytes = std::slice::from_raw_parts(wasm_bytes, len as usize);
    (*kernel).load_wasm(bytes)
}

/// Returns the number of NAM model slots declared by the loaded WASM module.
/// 0 when the module declares no NAM models.
///
/// # Safety
/// - `kernel` must be a valid pointer returned by `dsp_kernel_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsp_kernel_nam_path_count(kernel: DSPKernelRef) -> u32 {
    (*kernel).nam_paths().len() as u32
}

/// Returns the NAM model path declared at slot `idx`, or null if `idx` is out of range.
/// The returned pointer is valid until the next `load_wasm`, `dsp_kernel_destroy`, or
/// next call to this function.
///
/// # Safety
/// - `kernel` must be a valid pointer returned by `dsp_kernel_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsp_kernel_nam_path_at(
    kernel: DSPKernelRef,
    idx: u32,
) -> *const c_char {
    thread_local! {
        static NAM_PATH_CACHE: std::cell::RefCell<Option<std::ffi::CString>> = const { std::cell::RefCell::new(None) };
    }
    let paths = (*kernel).nam_paths();
    let i = idx as usize;
    if i >= paths.len() {
        return std::ptr::null();
    }
    NAM_PATH_CACHE.with(|cache| {
        let mut cache = cache.borrow_mut();
        *cache = std::ffi::CString::new(paths[i].as_str()).ok();
        cache.as_ref().map(|c| c.as_ptr()).unwrap_or(std::ptr::null())
    })
}

/// Inject NAM model binary data into the loaded WASM backend at the given slot.
/// Call after `dsp_kernel_load_wasm` for each path returned by `dsp_kernel_nam_path_at`.
/// Returns true on success.
///
/// # Safety
/// - `kernel` must be a valid pointer returned by `dsp_kernel_create`.
/// - `data` must point to `len` valid bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsp_kernel_inject_nam_slot(
    kernel: DSPKernelRef,
    slot: u32,
    data: *const u8,
    len: usize,
) -> bool {
    if data.is_null() || len == 0 {
        return false;
    }
    let bytes = std::slice::from_raw_parts(data, len);
    match (*kernel).inject_nam_slot(slot, bytes) {
        Ok(()) => true,
        Err(err) => {
            eprintln!("NAM injection failed (slot {}): {}", slot, err);
            (*kernel).set_last_error(Some(err));
            false
        }
    }
}

/// Benchmark the process function.
/// Returns the max execution time in seconds over 5 runs, or -1.0 if no script is loaded.
///
/// # Safety
/// `kernel` must be a valid pointer returned by `dsp_kernel_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsp_kernel_benchmark_process(kernel: DSPKernelRef) -> f64 {
    (*kernel).benchmark_process().unwrap_or(-1.0)
}

/// Monotonic counter that bumps on every state change to the kernel's
/// `last_error` (None → Some, Some → None, Some(x) → Some(y), and the
/// initial set). Swift polls this on a timer; only when it advances does
/// it re-read `dsp_kernel_last_error`. Lets the editor surface runtime
/// errors as Monaco markers without scanning the error string on every
/// poll.
///
/// # Safety
/// `kernel` must be a valid pointer returned by `dsp_kernel_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsp_kernel_error_generation(kernel: DSPKernelRef) -> u64 {
    (*kernel).error_generation()
}

/// Returns the last error message as a null-terminated C string.
/// Returns null if no error. The pointer is valid until the next call to this function or destroy.
///
/// # Safety
/// `kernel` must be a valid pointer returned by `dsp_kernel_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsp_kernel_last_error(kernel: DSPKernelRef) -> *const c_char {
    thread_local! {
        static LAST_ERR: std::cell::RefCell<Option<std::ffi::CString>> = const { std::cell::RefCell::new(None) };
    }
    match (*kernel).last_error() {
        Some(msg) => {
            let c_str = std::ffi::CString::new(msg).unwrap_or_default();
            LAST_ERR.with(|cell| {
                let mut borrow = cell.borrow_mut();
                *borrow = Some(c_str);
                borrow.as_ref().unwrap().as_ptr()
            })
        }
        None => std::ptr::null(),
    }
}

/// Atomic variant of `dsp_kernel_last_error` + `dsp_kernel_error_generation`.
/// Writes the current `error_generation` into `*out_generation` AND returns
/// the last error string (or null), with both values produced under the
/// same mutex lock so the pair is coherent. Use this when you've taken a
/// baseline `error_generation` and want to detect "did the kernel
/// transition to a new error since baseline?" without racing the audio
/// thread between the gen-read and string-read.
///
/// Same thread-local CString contract as `dsp_kernel_last_error`: the
/// returned pointer is valid until the next call to either function on
/// this thread or until `dsp_kernel_destroy`.
///
/// # Safety
/// `kernel` must be a valid pointer returned by `dsp_kernel_create`.
/// `out_generation` must be a valid `*mut u64` (may not be null).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsp_kernel_last_error_with_generation(
    kernel: DSPKernelRef,
    out_generation: *mut u64,
) -> *const c_char {
    thread_local! {
        static LAST_ERR: std::cell::RefCell<Option<std::ffi::CString>> = const { std::cell::RefCell::new(None) };
    }
    let (generation, msg) = (*kernel).last_error_with_generation();
    if !out_generation.is_null() {
        *out_generation = generation;
    }
    match msg {
        Some(msg) => {
            let c_str = std::ffi::CString::new(msg).unwrap_or_default();
            LAST_ERR.with(|cell| {
                let mut borrow = cell.borrow_mut();
                *borrow = Some(c_str);
                borrow.as_ref().unwrap().as_ptr()
            })
        }
        None => std::ptr::null(),
    }
}

/// Returns script-declared parameter names as a null-terminated JSON C string,
/// e.g. `{"0":"Cutoff","1":"Resonance"}`.
/// Returns null if the loaded script does not declare parameter names.
/// The pointer is valid until the next script load or kernel destroy.
///
/// # Safety
/// `kernel` must be a valid pointer returned by `dsp_kernel_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsp_kernel_param_names_json(kernel: DSPKernelRef) -> *const c_char {
    (*kernel).param_names_json_ptr()
}

/// Returns rich parameter metadata as a null-terminated JSON array string,
/// e.g. `[{"name":"Threshold","min":-40,"max":-3,"unit":"dB","default":-20}, ...]`.
/// Returns null if the loaded script does not declare a `PARAMS` dict.
/// The pointer is valid until the next script load or kernel destroy.
///
/// # Safety
/// `kernel` must be a valid pointer returned by `dsp_kernel_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsp_kernel_param_metadata_json(kernel: DSPKernelRef) -> *const c_char {
    (*kernel).param_metadata_json_ptr()
}

/// Returns the script-declared algorithmic latency in samples.
/// Zero means no latency. Used by the AU host to report
/// `AUAudioUnit.latency` for DAW delay compensation.
///
/// # Safety
/// `kernel` must be a valid pointer returned by `dsp_kernel_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsp_kernel_latency_samples(kernel: DSPKernelRef) -> u32 {
    (*kernel).latency_samples()
}

/// Returns a pointer to the cached telemetry slot metadata JSON
/// (`[{name, key?, unit}, …]`), or null when the script declared no
/// telemetry. Pointer is valid until the next script load or kernel
/// destroy; Swift caches the parsed slot names.
///
/// Telemetry is the read-back twin of `dsp_kernel_param_metadata_json`:
/// scripts publish internal DSP state per render block via
/// `Context::set_telemetry_scalar` / `TELEMETRY` dict, host UI reads
/// the snapshot via `dsp_kernel_read_telemetry`.
///
/// # Safety
/// `kernel` must be a valid pointer returned by `dsp_kernel_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsp_kernel_telemetry_metadata_json(
    kernel: DSPKernelRef,
) -> *const c_char {
    (*kernel).telemetry_metadata_json_ptr()
}

/// Snapshot the latest telemetry values published by the most recent
/// `process()` call into the caller's buffer. Writes up to `max`
/// slots (capped at the kernel's TELEMETRY_LEN, currently 16) and
/// returns the number written. Lock-free Relaxed read of per-slot
/// atomics; safe to call from any thread, throttled in practice to
/// display-link cadence (~30–120 Hz).
///
/// # Safety
/// - `kernel` must be a valid pointer returned by `dsp_kernel_create`.
/// - `out` must point to at least `max` writable f32 values.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsp_kernel_read_telemetry(
    kernel: DSPKernelRef,
    out: *mut f32,
    max: u32,
) -> u32 {
    let buf = std::slice::from_raw_parts_mut(out, max as usize);
    (*kernel).read_telemetry(buf) as u32
}

/// Snapshot the latest per-frame values written by the most recent
/// `process()` call for the vector telemetry slot at metadata position
/// `slot_index`. Writes up to `max` f32 values into `out` and returns
/// the number actually written. Returns 0 when the slot is scalar /
/// not declared / has not been written yet, or when the script is on
/// a backend that doesn't support vector telemetry.
///
/// Brief lock under the hood (see `DSPKernel::read_telemetry_vec`);
/// safe to call from the UI / display-link thread at ~30–120 Hz.
///
/// # Safety
/// - `kernel` must be a valid pointer returned by `dsp_kernel_create`.
/// - `out` must point to at least `max` writable f32 values.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsp_kernel_read_telemetry_vec(
    kernel: DSPKernelRef,
    slot_index: u32,
    out: *mut f32,
    max: u32,
) -> u32 {
    let buf = std::slice::from_raw_parts_mut(out, max as usize);
    (*kernel).read_telemetry_vec(slot_index as usize, buf) as u32
}

/// Enable or disable audio capture for spectrogram visualization.
/// When disabled, ring buffers are not written to (saves CPU on audio thread).
///
/// # Safety
/// `kernel` must be a valid pointer returned by `dsp_kernel_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsp_kernel_set_capture_enabled(kernel: DSPKernelRef, enabled: bool) {
    (*kernel).set_capture_enabled(enabled);
}

/// Read available samples from the input (pre-processing) ring buffer.
/// Returns the number of samples actually read (up to `max_samples`).
/// Called from the UI thread only.
///
/// # Safety
/// - `kernel` must be a valid pointer returned by `dsp_kernel_create`.
/// - `out` must point to at least `max_samples` writable f32 values.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsp_kernel_read_input_ring(
    kernel: DSPKernelRef,
    out: *mut f32,
    max_samples: u32,
) -> u32 {
    let output = std::slice::from_raw_parts_mut(out, max_samples as usize);
    (*kernel).read_input_ring(output) as u32
}

/// Read available samples from the output (post-processing) ring buffer.
/// Returns the number of samples actually read (up to `max_samples`).
/// Called from the UI thread only.
///
/// # Safety
/// - `kernel` must be a valid pointer returned by `dsp_kernel_create`.
/// - `out` must point to at least `max_samples` writable f32 values.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsp_kernel_read_output_ring(
    kernel: DSPKernelRef,
    out: *mut f32,
    max_samples: u32,
) -> u32 {
    let output = std::slice::from_raw_parts_mut(out, max_samples as usize);
    (*kernel).read_output_ring(output) as u32
}

/// Verify a subscription token's signature and expiry, then set the kernel's
/// subscription status and licensed flag.
///
/// Returns a `SubscriptionStatus` value (0=Active, 1=GracePeriod, 2=Expired,
/// 3=Cancelled, 4=NoSubscription).
///
/// # Safety
/// - `kernel` must be a valid pointer returned by `dsp_kernel_create`.
/// - `token` must be a valid null-terminated C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsp_kernel_verify_token(
    kernel: DSPKernelRef,
    token: *const c_char,
) -> u8 {
    let token_str = match CStr::from_ptr(token).to_str() {
        Ok(s) => s,
        Err(_) => return license::SubscriptionStatus::NoSubscription as u8,
    };
    match license::verify_token(token_str) {
        Ok(payload) => {
            // Get current Unix time
            let now_unix = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs() as i64)
                .unwrap_or(0);
            let status = license::check_token_status(&payload, now_unix);
            let deadline = license::grace_deadline_from_token(&payload);
            (*kernel).set_subscription_status(status);
            (*kernel).set_grace_deadline_unix(deadline);
            status as u8
        }
        Err(e) => {
            (*kernel).set_last_error(Some(format!("Token verification failed: {}", e)));
            (*kernel).set_subscription_status(license::SubscriptionStatus::NoSubscription);
            license::SubscriptionStatus::NoSubscription as u8
        }
    }
}

/// Check if the kernel has a valid license.
///
/// # Safety
/// `kernel` must be a valid pointer returned by `dsp_kernel_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsp_kernel_is_licensed(kernel: DSPKernelRef) -> bool {
    (*kernel).is_licensed()
}

/// Get the remaining demo time in seconds at the given sample rate.
/// Returns infinity if licensed.
///
/// # Safety
/// `kernel` must be a valid pointer returned by `dsp_kernel_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsp_kernel_demo_seconds_remaining(
    kernel: DSPKernelRef,
    sample_rate: f64,
) -> f64 {
    (*kernel).demo_seconds_remaining(sample_rate)
}

/// Set the subscription status directly (for restoring from cached token
/// or when the Swift layer determines the status via server call).
///
/// Status values: 0=Active, 1=GracePeriod, 2=Expired, 3=Cancelled, 4=NoSubscription
///
/// # Safety
/// `kernel` must be a valid pointer returned by `dsp_kernel_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsp_kernel_set_subscription_status(kernel: DSPKernelRef, status: u8) {
    let s = license::SubscriptionStatus::from_u8(status);
    (*kernel).set_subscription_status(s);
}

/// Get the current subscription status.
///
/// Returns: 0=Active, 1=GracePeriod, 2=Expired, 3=Cancelled, 4=NoSubscription
///
/// # Safety
/// `kernel` must be a valid pointer returned by `dsp_kernel_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsp_kernel_subscription_status(kernel: DSPKernelRef) -> u8 {
    (*kernel).subscription_status() as u8
}

/// Get the grace period deadline as Unix seconds.
/// Returns 0 if no token has been verified.
///
/// # Safety
/// `kernel` must be a valid pointer returned by `dsp_kernel_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsp_kernel_grace_deadline_unix(kernel: DSPKernelRef) -> i64 {
    (*kernel).grace_deadline_unix()
}

/// Set the licensed state directly (for restoring from persisted license).
///
/// # Safety
/// `kernel` must be a valid pointer returned by `dsp_kernel_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsp_kernel_set_licensed(kernel: DSPKernelRef, licensed: bool) {
    (*kernel).set_licensed(licensed);
}

/// Reset the demo sample counter, giving another 60 seconds of demo time.
///
/// # Safety
/// `kernel` must be a valid pointer returned by `dsp_kernel_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsp_kernel_reset_demo(kernel: DSPKernelRef) {
    (*kernel).reset_demo();
}

/// Return a pointer to the embedded Ed25519 public key (32 bytes).
/// Only available in debug builds for diagnostics. Returns null in release.
#[unsafe(no_mangle)]
pub extern "C" fn dsp_kernel_public_key() -> *const u8 {
    #[cfg(debug_assertions)]
    {
        // Leak a boxed copy so the pointer is stable for the caller.
        let key = Box::new(license::public_key_bytes());
        Box::leak(key).as_ptr()
    }
    #[cfg(not(debug_assertions))]
    {
        std::ptr::null()
    }
}

/// Get the most recent backend.process() duration in microseconds.
/// Returns 0 when no backend has processed yet.
///
/// # Safety
/// `kernel` must be a valid pointer returned by `dsp_kernel_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsp_kernel_profiler_current_us(kernel: DSPKernelRef) -> u32 {
    (*kernel).profiler_current_us.load(std::sync::atomic::Ordering::Relaxed)
}

/// Get the exponential moving average of backend.process() duration in microseconds.
/// Smoothed over ~0.5 seconds of callbacks.
///
/// # Safety
/// `kernel` must be a valid pointer returned by `dsp_kernel_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsp_kernel_profiler_avg_us(kernel: DSPKernelRef) -> u32 {
    (*kernel).profiler_avg_us.load(std::sync::atomic::Ordering::Relaxed)
}

/// Get the decaying peak of backend.process() duration in microseconds.
/// Decays by ~0.1% per callback, so peaks fade after a few seconds.
///
/// # Safety
/// `kernel` must be a valid pointer returned by `dsp_kernel_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsp_kernel_profiler_peak_us(kernel: DSPKernelRef) -> u32 {
    (*kernel).profiler_peak_us.load(std::sync::atomic::Ordering::Relaxed)
}

// --- Memory monitoring FFI ---

/// Get the current process resident memory in bytes via mach task_info.
/// Does not require a kernel — measures process-wide RSS.
/// Returns 0 on failure. Safe to call from any thread (~1µs).
#[unsafe(no_mangle)]
pub extern "C" fn dsp_kernel_process_resident_bytes() -> u64 {
    kernel::process_resident_bytes()
}

/// Get the process RSS baseline recorded when the current script was loaded.
///
/// # Safety
/// `kernel` must be a valid pointer returned by `dsp_kernel_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsp_kernel_memory_baseline_bytes(kernel: DSPKernelRef) -> u64 {
    (*kernel).memory_baseline_bytes()
}

/// Get the current WASM linear memory size in bytes.
/// Returns 0 if the current backend is not WASM.
///
/// # Safety
/// `kernel` must be a valid pointer returned by `dsp_kernel_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsp_kernel_wasm_memory_bytes(kernel: DSPKernelRef) -> u64 {
    (*kernel).wasm_memory_bytes()
}

/// Get the actual frame count from the most recent render callback.
/// Returns 0 before the first render call. Use this instead of
/// `dsp_kernel_get_max_frames` to display the true audio budget, since
/// DAW buffer sizes below the AU framework minimum (64) are clamped in
/// `maximumFramesToRender` but still arrive as smaller `frameCount` values
/// in the render block.
///
/// # Safety
/// `kernel` must be a valid pointer returned by `dsp_kernel_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsp_kernel_last_render_frame_count(kernel: DSPKernelRef) -> u32 {
    (*kernel).last_render_frame_count()
}

// ─── State channel FFI ────────────────────────────────────────────────
//
// The state channel is a per-instance JSON byte buffer that flows from
// custom UI / MCP writers into the audio thread for backend consumption.
// State is owned by the DAW project (or user preset bundle) — see the
// AU's `fullState` / `fullStateForDocument` overrides — and never written
// to disk inside the bundle.

/// Set the per-script cap on the state buffer in bytes. Called by Swift
/// at script load (passes the script's declared `max_bytes` from
/// `state!(T, max_bytes = N)` in Rust, or the default 64 KiB for Python
/// presets which currently have no opt-in syntax). Subsequent
/// `dsp_kernel_set_state_json` calls reject inputs over this size.
///
/// # Safety
/// `kernel` must be a valid pointer returned by `dsp_kernel_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsp_kernel_set_state_cap(kernel: DSPKernelRef, max_bytes: usize) {
    (*kernel).set_state_cap(max_bytes);
}

/// Returns the currently configured state cap in bytes.
///
/// # Safety
/// `kernel` must be a valid pointer returned by `dsp_kernel_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsp_kernel_state_cap(kernel: DSPKernelRef) -> usize {
    (*kernel).state_cap()
}

/// Try to install a new state buffer. Validates that the bytes are
/// well-formed JSON and within the per-script cap. Returns `true` on
/// success, `false` on rejection. On failure the existing buffer +
/// generation are unchanged.
///
/// # Safety
/// - `kernel` must be a valid pointer returned by `dsp_kernel_create`.
/// - `bytes` must be a valid pointer to `len` bytes (or null when len==0).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsp_kernel_set_state_json(
    kernel: DSPKernelRef,
    bytes: *const u8,
    len: usize,
) -> bool {
    let slice = if len == 0 || bytes.is_null() {
        b"{}".as_ref()
    } else {
        std::slice::from_raw_parts(bytes, len)
    };
    (*kernel).set_state_json_bytes(slice)
}

/// Copy the current state buffer into the caller-provided buffer.
/// Writes up to `max_len` bytes and returns the actual length the kernel
/// wanted to write (so callers can detect truncation). Pass `out=null,
/// max_len=0` to query length only.
///
/// # Safety
/// - `kernel` must be a valid pointer returned by `dsp_kernel_create`.
/// - When `max_len > 0`, `out` must be valid for `max_len` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsp_kernel_get_state_json(
    kernel: DSPKernelRef,
    out: *mut u8,
    max_len: usize,
) -> usize {
    let bytes = (*kernel).state_json_bytes_copy();
    let want = bytes.len();
    if max_len > 0 && !out.is_null() {
        let n = want.min(max_len);
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), out, n);
    }
    want
}

/// Read the current state generation counter without taking the buffer.
/// Used by the smoke tester to verify that a UI write actually landed.
///
/// # Safety
/// `kernel` must be a valid pointer returned by `dsp_kernel_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsp_kernel_state_generation(kernel: DSPKernelRef) -> u64 {
    (*kernel).state_generation()
}

/// Returns a pointer to the most recently loaded backend's STATE
/// defaults JSON, or null when none was declared (Python-only
/// concept — WASM gets defaults from its `Default` impl). Pointer is
/// valid until the next script load or kernel destroy.
///
/// # Safety
/// `kernel` must be a valid pointer returned by `dsp_kernel_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dsp_kernel_state_defaults_json(kernel: DSPKernelRef) -> *const c_char {
    (*kernel).state_defaults_json_ptr()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Verifies the debug-only panic hook actually writes its log file
    /// to the App Group container. `dsp_kernel_create` installs the hook;
    /// we then trigger a panic under `catch_unwind` (so the test process
    /// survives) with a distinctive marker, and confirm the file contains
    /// our marker plus the expected RUST PANIC / location / backtrace
    /// sections.
    ///
    /// Other tests in this binary that panic via `assert!` etc. will also
    /// fire the hook and overwrite the file, so we explicitly trigger
    /// our own panic last in this test body and rely on file overwrite
    /// for isolation. Marker is unique so a parallel-test-runner race
    /// would still be detectable (we'd see a different marker).
    #[cfg(debug_assertions)]
    #[test]
    fn test_panic_logger_writes_to_app_group_container() {
        let kernel = dsp_kernel_create();
        unsafe { dsp_kernel_destroy(kernel); }

        let marker = "TEST_PANIC_LOGGER_MARKER_UV92QF";
        let _ = std::panic::catch_unwind(|| {
            panic!("{marker}");
        });

        let home = std::env::var("HOME").expect("HOME is set in test env");
        let path = format!(
            "{home}/Library/Group Containers/group.com.MichaelJancsy.ConjureDSP/rust-panic.log"
        );
        let content = std::fs::read_to_string(&path).unwrap_or_else(|e| {
            panic!("panic log file at {path} should exist after panic: {e}")
        });

        assert!(
            content.contains(marker),
            "log file should contain the test's panic marker. content:\n{content}"
        );
        assert!(content.contains("RUST PANIC"), "missing RUST PANIC header. content:\n{content}");
        assert!(content.contains("location:"), "missing location field. content:\n{content}");
        assert!(content.contains("payload:"), "missing payload field. content:\n{content}");
        assert!(content.contains("backtrace:"), "missing backtrace field. content:\n{content}");
    }

    #[test]
    fn test_ffi_create_destroy() {
        let kernel = dsp_kernel_create();
        assert!(!kernel.is_null());
        unsafe { dsp_kernel_destroy(kernel); }
    }

    #[test]
    fn test_ffi_destroy_null() {
        unsafe { dsp_kernel_destroy(std::ptr::null_mut()); }
    }

    #[test]
    fn test_ffi_create_multiple() {
        let k1 = dsp_kernel_create();
        let k2 = dsp_kernel_create();
        assert!(!k1.is_null());
        assert!(!k2.is_null());
        assert_ne!(k1, k2);
        unsafe {
            dsp_kernel_set_bypassed(k1, true);
            assert!(dsp_kernel_is_bypassed(k1));
            assert!(!dsp_kernel_is_bypassed(k2));
            dsp_kernel_destroy(k1);
            dsp_kernel_destroy(k2);
        }
    }

    #[test]
    fn test_ffi_bypass_roundtrip() {
        let kernel = dsp_kernel_create();
        unsafe {
            assert!(!dsp_kernel_is_bypassed(kernel));
            dsp_kernel_set_bypassed(kernel, true);
            assert!(dsp_kernel_is_bypassed(kernel));
            dsp_kernel_set_bypassed(kernel, false);
            assert!(!dsp_kernel_is_bypassed(kernel));
            dsp_kernel_destroy(kernel);
        }
    }

    #[test]
    fn test_ffi_initialize_deinitialize() {
        let kernel = dsp_kernel_create();
        unsafe {
            dsp_kernel_initialize(kernel, 2, 2, 48000.0);
            dsp_kernel_deinitialize(kernel);
            dsp_kernel_destroy(kernel);
        }
    }

    #[test]
    fn test_ffi_max_frames_roundtrip() {
        let kernel = dsp_kernel_create();
        unsafe {
            assert_eq!(dsp_kernel_get_max_frames(kernel), 1024);
            dsp_kernel_set_max_frames(kernel, 512);
            assert_eq!(dsp_kernel_get_max_frames(kernel), 512);
            dsp_kernel_destroy(kernel);
        }
    }

    #[test]
    fn test_ffi_parameter_roundtrip() {
        let kernel = dsp_kernel_create();
        unsafe {
            // Valid addresses (0–7) should round-trip
            assert_eq!(dsp_kernel_get_parameter(kernel, 0), 0.0);
            dsp_kernel_set_parameter(kernel, 0, 0.75);
            assert_eq!(dsp_kernel_get_parameter(kernel, 0), 0.75);

            // All 16 parameters
            for addr in 0..16u64 {
                dsp_kernel_set_parameter(kernel, addr, (addr + 1) as f32 * 0.05);
            }
            for addr in 0..16u64 {
                let expected = (addr + 1) as f32 * 0.05;
                let actual = dsp_kernel_get_parameter(kernel, addr);
                assert!((actual - expected).abs() < 1e-6, "addr={} expected={} got={}", addr, expected, actual);
            }

            // Out-of-range address returns 0.0
            assert_eq!(dsp_kernel_get_parameter(kernel, 16), 0.0);
            assert_eq!(dsp_kernel_get_parameter(kernel, 17), 0.0);
            assert_eq!(dsp_kernel_get_parameter(kernel, 999), 0.0);

            dsp_kernel_destroy(kernel);
        }
    }

    #[test]
    fn test_ffi_process_passthrough() {
        let kernel = dsp_kernel_create();
        unsafe {
            dsp_kernel_initialize(kernel, 1, 1, 44100.0);

            let input: [f32; 4] = [0.1, 0.2, 0.3, 0.4];
            let mut output: [f32; 4] = [0.0; 4];
            let ip: *const f32 = input.as_ptr();
            let op: *mut f32 = output.as_mut_ptr();

            dsp_kernel_process(kernel, &ip, &op, 1, 4);
            assert_eq!(output, [0.1, 0.2, 0.3, 0.4]);

            dsp_kernel_deinitialize(kernel);
            dsp_kernel_destroy(kernel);
        }
    }

    #[test]
    fn test_ffi_last_error_initially_null() {
        let kernel = dsp_kernel_create();
        unsafe {
            let err = dsp_kernel_last_error(kernel);
            assert!(err.is_null());
            dsp_kernel_destroy(kernel);
        }
    }

    #[test]
    fn test_ffi_full_lifecycle() {
        let kernel = dsp_kernel_create();
        unsafe {
            dsp_kernel_initialize(kernel, 2, 2, 44100.0);
            dsp_kernel_set_max_frames(kernel, 256);

            let input_l: [f32; 4] = [1.0, 0.5, -1.0, 0.0];
            let input_r: [f32; 4] = [0.0, -0.5, 1.0, 0.25];
            let mut output_l: [f32; 4] = [0.0; 4];
            let mut output_r: [f32; 4] = [0.0; 4];

            let input_ptrs: [*const f32; 2] = [input_l.as_ptr(), input_r.as_ptr()];
            let output_ptrs: [*mut f32; 2] = [output_l.as_mut_ptr(), output_r.as_mut_ptr()];

            dsp_kernel_process(kernel, input_ptrs.as_ptr(), output_ptrs.as_ptr(), 2, 4);
            assert_eq!(output_l, [1.0, 0.5, -1.0, 0.0]);
            assert_eq!(output_r, [0.0, -0.5, 1.0, 0.25]);

            dsp_kernel_deinitialize(kernel);
            dsp_kernel_destroy(kernel);
        }
    }

    #[test]
    fn test_ffi_benchmark_no_script() {
        let kernel = dsp_kernel_create();
        unsafe {
            let result = dsp_kernel_benchmark_process(kernel);
            assert_eq!(result, -1.0);
            dsp_kernel_destroy(kernel);
        }
    }

    fn passthrough_wasm_bytes() -> Vec<u8> {
        // Post-1cc3aff ABI: zero-arg process(), BlockInfo at offset 16,
        // module-allocated input at 1024, output at 32768.
        wat::parse_str(r#"
            (module
              (memory (export "memory") 1)
              (func (export "get_block_info_ptr") (result i32) (i32.const 16))
              (func (export "get_input_ptr")      (result i32) (i32.const 1024))
              (func (export "get_output_ptr")     (result i32) (i32.const 32768))
              (func (export "process")
                (local $i i32)
                (local $total i32)
                (local.set $total
                  (i32.mul
                    (i32.load (i32.const 16))
                    (i32.load (i32.const 20))))
                (block $break
                  (loop $loop
                    (br_if $break (i32.ge_u (local.get $i) (local.get $total)))
                    (f32.store
                      (i32.add (i32.const 32768) (i32.mul (local.get $i) (i32.const 4)))
                      (f32.load (i32.add (i32.const 1024) (i32.mul (local.get $i) (i32.const 4))))
                    )
                    (local.set $i (i32.add (local.get $i) (i32.const 1)))
                    (br $loop)
                  )
                )
              )
            )
        "#).expect("Failed to parse WAT")
    }

    #[test]
    fn test_ffi_load_wasm() {
        let wasm = passthrough_wasm_bytes();
        let kernel = dsp_kernel_create();
        unsafe {
            let result = dsp_kernel_load_wasm(kernel, wasm.as_ptr(), wasm.len() as u32);
            assert!(result);
            dsp_kernel_destroy(kernel);
        }
    }

    #[test]
    fn test_ffi_load_wasm_null_bytes() {
        let kernel = dsp_kernel_create();
        unsafe {
            let result = dsp_kernel_load_wasm(kernel, std::ptr::null(), 0);
            assert!(!result);
            dsp_kernel_destroy(kernel);
        }
    }

    #[test]
    fn test_ffi_load_wasm_invalid_bytes() {
        let kernel = dsp_kernel_create();
        let garbage: [u8; 4] = [0xFF, 0xFF, 0xFF, 0xFF];
        unsafe {
            let result = dsp_kernel_load_wasm(kernel, garbage.as_ptr(), garbage.len() as u32);
            assert!(!result);
            let err = dsp_kernel_last_error(kernel);
            assert!(!err.is_null());
            dsp_kernel_destroy(kernel);
        }
    }

    #[test]
    fn test_ffi_wasm_process() {
        let wasm = passthrough_wasm_bytes();
        let kernel = dsp_kernel_create();
        unsafe {
            assert!(dsp_kernel_load_wasm(kernel, wasm.as_ptr(), wasm.len() as u32));
            dsp_kernel_initialize(kernel, 1, 1, 44100.0);

            let input: [f32; 4] = [0.1, 0.2, 0.3, 0.4];
            let mut output: [f32; 4] = [0.0; 4];
            let ip: *const f32 = input.as_ptr();
            let op: *mut f32 = output.as_mut_ptr();

            dsp_kernel_process(kernel, &ip, &op, 1, 4);
            assert_eq!(output, [0.1, 0.2, 0.3, 0.4]);

            dsp_kernel_deinitialize(kernel);
            dsp_kernel_destroy(kernel);
        }
    }

    #[test]
    fn test_ffi_wasm_benchmark() {
        let wasm = passthrough_wasm_bytes();
        let kernel = dsp_kernel_create();
        unsafe {
            assert!(dsp_kernel_load_wasm(kernel, wasm.as_ptr(), wasm.len() as u32));
            dsp_kernel_initialize(kernel, 1, 1, 44100.0);

            let result = dsp_kernel_benchmark_process(kernel);
            assert!(result > 0.0, "benchmark should return positive time, got {}", result);

            dsp_kernel_deinitialize(kernel);
            dsp_kernel_destroy(kernel);
        }
    }

    #[test]
    fn test_ffi_capture_disabled_by_default() {
        let kernel = dsp_kernel_create();
        unsafe {
            dsp_kernel_initialize(kernel, 1, 1, 44100.0);

            let input: [f32; 4] = [0.1, 0.2, 0.3, 0.4];
            let mut output: [f32; 4] = [0.0; 4];
            let ip: *const f32 = input.as_ptr();
            let op: *mut f32 = output.as_mut_ptr();

            dsp_kernel_process(kernel, &ip, &op, 1, 4);

            // Ring buffers should be empty when capture is disabled
            let mut ring_out = [0.0f32; 4];
            let count = dsp_kernel_read_input_ring(kernel, ring_out.as_mut_ptr(), 4);
            assert_eq!(count, 0);
            let count = dsp_kernel_read_output_ring(kernel, ring_out.as_mut_ptr(), 4);
            assert_eq!(count, 0);

            dsp_kernel_destroy(kernel);
        }
    }

    #[test]
    fn test_ffi_capture_enabled_captures_passthrough() {
        let kernel = dsp_kernel_create();
        unsafe {
            dsp_kernel_initialize(kernel, 1, 1, 44100.0);
            dsp_kernel_set_capture_enabled(kernel, true);

            let input: [f32; 4] = [0.1, 0.2, 0.3, 0.4];
            let mut output: [f32; 4] = [0.0; 4];
            let ip: *const f32 = input.as_ptr();
            let op: *mut f32 = output.as_mut_ptr();

            dsp_kernel_process(kernel, &ip, &op, 1, 4);

            // Both ring buffers should have data
            let mut ring_in = [0.0f32; 4];
            let count = dsp_kernel_read_input_ring(kernel, ring_in.as_mut_ptr(), 4);
            assert_eq!(count, 4);
            assert_eq!(ring_in, [0.1, 0.2, 0.3, 0.4]);

            let mut ring_out = [0.0f32; 4];
            let count = dsp_kernel_read_output_ring(kernel, ring_out.as_mut_ptr(), 4);
            assert_eq!(count, 4);
            // Passthrough: output should match input
            assert_eq!(ring_out, [0.1, 0.2, 0.3, 0.4]);

            dsp_kernel_destroy(kernel);
        }
    }

    #[test]
    fn test_ffi_capture_stereo_mono_downmix() {
        let kernel = dsp_kernel_create();
        unsafe {
            dsp_kernel_initialize(kernel, 2, 2, 44100.0);
            dsp_kernel_set_capture_enabled(kernel, true);

            let input_l: [f32; 4] = [1.0, 0.5, -1.0, 0.0];
            let input_r: [f32; 4] = [0.0, 0.5, 1.0, 0.0];
            let mut output_l: [f32; 4] = [0.0; 4];
            let mut output_r: [f32; 4] = [0.0; 4];

            let input_ptrs: [*const f32; 2] = [input_l.as_ptr(), input_r.as_ptr()];
            let output_ptrs: [*mut f32; 2] = [output_l.as_mut_ptr(), output_r.as_mut_ptr()];

            dsp_kernel_process(kernel, input_ptrs.as_ptr(), output_ptrs.as_ptr(), 2, 4);

            // Ring buffer should contain mono downmix: (L + R) / 2
            let mut ring_in = [0.0f32; 4];
            let count = dsp_kernel_read_input_ring(kernel, ring_in.as_mut_ptr(), 4);
            assert_eq!(count, 4);
            assert_eq!(ring_in, [0.5, 0.5, 0.0, 0.0]);

            dsp_kernel_destroy(kernel);
        }
    }

    #[test]
    fn test_ffi_capture_with_wasm_backend() {
        let wasm = passthrough_wasm_bytes();
        let kernel = dsp_kernel_create();
        unsafe {
            assert!(dsp_kernel_load_wasm(kernel, wasm.as_ptr(), wasm.len() as u32));
            dsp_kernel_initialize(kernel, 1, 1, 44100.0);
            dsp_kernel_set_capture_enabled(kernel, true);

            let input: [f32; 4] = [0.5, -0.5, 0.25, -0.25];
            let mut output: [f32; 4] = [0.0; 4];
            let ip: *const f32 = input.as_ptr();
            let op: *mut f32 = output.as_mut_ptr();

            dsp_kernel_process(kernel, &ip, &op, 1, 4);

            // Both ring buffers should have captured data
            let mut ring_in = [0.0f32; 4];
            let count = dsp_kernel_read_input_ring(kernel, ring_in.as_mut_ptr(), 4);
            assert_eq!(count, 4);
            assert_eq!(ring_in, [0.5, -0.5, 0.25, -0.25]);

            let mut ring_out = [0.0f32; 4];
            let count = dsp_kernel_read_output_ring(kernel, ring_out.as_mut_ptr(), 4);
            assert_eq!(count, 4);
            // WASM passthrough: output matches input
            assert_eq!(ring_out, [0.5, -0.5, 0.25, -0.25]);

            dsp_kernel_deinitialize(kernel);
            dsp_kernel_destroy(kernel);
        }
    }

    #[test]
    fn test_ffi_capture_toggle() {
        let kernel = dsp_kernel_create();
        unsafe {
            dsp_kernel_initialize(kernel, 1, 1, 44100.0);

            let input: [f32; 4] = [0.1, 0.2, 0.3, 0.4];
            let mut output: [f32; 4] = [0.0; 4];
            let ip: *const f32 = input.as_ptr();
            let op: *mut f32 = output.as_mut_ptr();

            // Enable, process, verify capture
            dsp_kernel_set_capture_enabled(kernel, true);
            dsp_kernel_process(kernel, &ip, &op, 1, 4);
            let mut ring_in = [0.0f32; 4];
            let count = dsp_kernel_read_input_ring(kernel, ring_in.as_mut_ptr(), 4);
            assert_eq!(count, 4);

            // Disable, process, verify no capture
            dsp_kernel_set_capture_enabled(kernel, false);
            dsp_kernel_process(kernel, &ip, &op, 1, 4);
            let count = dsp_kernel_read_input_ring(kernel, ring_in.as_mut_ptr(), 4);
            assert_eq!(count, 0);

            dsp_kernel_destroy(kernel);
        }
    }

    // --- License FFI tests ---

    #[test]
    fn test_ffi_license_default_unlicensed() {
        let kernel = dsp_kernel_create();
        unsafe {
            assert!(!dsp_kernel_is_licensed(kernel));
            dsp_kernel_destroy(kernel);
        }
    }

    #[test]
    fn test_ffi_set_licensed_roundtrip() {
        let kernel = dsp_kernel_create();
        unsafe {
            assert!(!dsp_kernel_is_licensed(kernel));
            dsp_kernel_set_licensed(kernel, true);
            assert!(dsp_kernel_is_licensed(kernel));
            dsp_kernel_set_licensed(kernel, false);
            assert!(!dsp_kernel_is_licensed(kernel));
            dsp_kernel_destroy(kernel);
        }
    }

    #[test]
    fn test_ffi_demo_seconds_remaining() {
        let kernel = dsp_kernel_create();
        unsafe {
            dsp_kernel_initialize(kernel, 1, 1, 48000.0);
            let remaining = dsp_kernel_demo_seconds_remaining(kernel, 48000.0);
            assert!((remaining - 60.0).abs() < 0.1);

            dsp_kernel_set_licensed(kernel, true);
            let remaining = dsp_kernel_demo_seconds_remaining(kernel, 48000.0);
            assert!(remaining.is_infinite());

            dsp_kernel_destroy(kernel);
        }
    }

    #[test]
    fn test_ffi_verify_token_invalid() {
        let kernel = dsp_kernel_create();
        unsafe {
            let token = std::ffi::CString::new("invalid.token").unwrap();
            let result = dsp_kernel_verify_token(kernel, token.as_ptr());
            assert_eq!(result, license::SubscriptionStatus::NoSubscription as u8);
            assert!(!dsp_kernel_is_licensed(kernel));

            // Should have set an error message
            let err = dsp_kernel_last_error(kernel);
            assert!(!err.is_null());

            dsp_kernel_destroy(kernel);
        }
    }

    #[test]
    fn test_ffi_subscription_status() {
        let kernel = dsp_kernel_create();
        unsafe {
            // Default is NoSubscription
            assert_eq!(dsp_kernel_subscription_status(kernel), 4);

            // Set to Active
            dsp_kernel_set_subscription_status(kernel, 0);
            assert_eq!(dsp_kernel_subscription_status(kernel), 0);
            assert!(dsp_kernel_is_licensed(kernel));

            // Set to Expired
            dsp_kernel_set_subscription_status(kernel, 2);
            assert_eq!(dsp_kernel_subscription_status(kernel), 2);
            assert!(!dsp_kernel_is_licensed(kernel));

            dsp_kernel_destroy(kernel);
        }
    }

    #[test]
    fn test_ffi_param_names_json_no_script() {
        let kernel = dsp_kernel_create();
        unsafe {
            let ptr = dsp_kernel_param_names_json(kernel);
            assert!(ptr.is_null(), "No script loaded = no param names");
            dsp_kernel_destroy(kernel);
        }
    }

    #[test]
    fn test_ffi_param_names_json_wasm_with_names() {
        let json = r#"{"0":"Gain"}"#;
        let hex: String = json.bytes().map(|b| format!("\\{:02x}", b)).collect();
        let wat = format!(
            r#"
            (module
              (memory (export "memory") 1)
              (data (i32.const 1024) "{hex}")
              (func (export "get_block_info_ptr") (result i32) (i32.const 16))
              (func (export "process"))
              (func (export "get_param_names_json") (result i32 i32)
                (i32.const 1024)
                (i32.const {len})
              )
            )
            "#,
            hex = hex,
            len = json.len(),
        );
        let wasm = wat::parse_str(&wat).expect("WAT parse failed");

        let kernel = dsp_kernel_create();
        unsafe {
            let loaded = dsp_kernel_load_wasm(kernel, wasm.as_ptr(), wasm.len() as u32);
            assert!(loaded);

            let ptr = dsp_kernel_param_names_json(kernel);
            assert!(!ptr.is_null());
            let json_str = std::ffi::CStr::from_ptr(ptr).to_str().unwrap();
            assert!(json_str.contains("Gain"));

            dsp_kernel_destroy(kernel);
        }
    }

    #[test]
    fn test_ffi_profiler_initially_zero() {
        let kernel = dsp_kernel_create();
        unsafe {
            assert_eq!(dsp_kernel_profiler_current_us(kernel), 0);
            assert_eq!(dsp_kernel_profiler_avg_us(kernel), 0);
            assert_eq!(dsp_kernel_profiler_peak_us(kernel), 0);
            dsp_kernel_destroy(kernel);
        }
    }

    #[test]
    fn test_ffi_profiler_updates_after_wasm_process() {
        let wasm = passthrough_wasm_bytes();
        let kernel = dsp_kernel_create();
        unsafe {
            assert!(dsp_kernel_load_wasm(kernel, wasm.as_ptr(), wasm.len() as u32));
            dsp_kernel_initialize(kernel, 1, 1, 44100.0);

            let input: [f32; 4] = [0.1, 0.2, 0.3, 0.4];
            let mut output: [f32; 4] = [0.0; 4];
            let ip: *const f32 = input.as_ptr();
            let op: *mut f32 = output.as_mut_ptr();

            // Process multiple times so EMA accumulates (integer division
            // means a single 1µs sample gives avg=0: (5*1+251*0)/256=0)
            for _ in 0..100 {
                dsp_kernel_process(kernel, &ip, &op, 1, 4);
            }

            // After processing with a backend, profiler should have non-zero values
            assert!(dsp_kernel_profiler_current_us(kernel) > 0);
            assert!(dsp_kernel_profiler_avg_us(kernel) > 0);
            assert!(dsp_kernel_profiler_peak_us(kernel) > 0);

            dsp_kernel_deinitialize(kernel);
            dsp_kernel_destroy(kernel);
        }
    }

    #[test]
    fn test_ffi_profiler_resets_on_load() {
        let wasm = passthrough_wasm_bytes();
        let kernel = dsp_kernel_create();
        unsafe {
            assert!(dsp_kernel_load_wasm(kernel, wasm.as_ptr(), wasm.len() as u32));
            dsp_kernel_initialize(kernel, 1, 1, 44100.0);

            // Process to populate profiler
            let input: [f32; 4] = [0.1, 0.2, 0.3, 0.4];
            let mut output: [f32; 4] = [0.0; 4];
            let ip: *const f32 = input.as_ptr();
            let op: *mut f32 = output.as_mut_ptr();
            dsp_kernel_process(kernel, &ip, &op, 1, 4);
            assert!(dsp_kernel_profiler_current_us(kernel) > 0);

            // Load a new WASM module — profiler should reset
            assert!(dsp_kernel_load_wasm(kernel, wasm.as_ptr(), wasm.len() as u32));
            assert_eq!(dsp_kernel_profiler_current_us(kernel), 0);
            assert_eq!(dsp_kernel_profiler_avg_us(kernel), 0);
            assert_eq!(dsp_kernel_profiler_peak_us(kernel), 0);

            dsp_kernel_deinitialize(kernel);
            dsp_kernel_destroy(kernel);
        }
    }

    // --- Memory monitoring tests ---

    #[test]
    fn test_ffi_process_resident_bytes_nonzero() {
        // Any running process has nonzero RSS
        let bytes = dsp_kernel_process_resident_bytes();
        assert!(bytes > 0, "process resident bytes should be nonzero, got {bytes}");
    }

    #[test]
    fn test_ffi_memory_baseline_initially_zero() {
        let kernel = dsp_kernel_create();
        unsafe {
            assert_eq!(dsp_kernel_memory_baseline_bytes(kernel), 0);
            assert_eq!(dsp_kernel_wasm_memory_bytes(kernel), 0);
            dsp_kernel_destroy(kernel);
        }
    }

    #[test]
    fn test_ffi_memory_baseline_set_on_wasm_load() {
        let wasm = passthrough_wasm_bytes();
        let kernel = dsp_kernel_create();
        unsafe {
            assert_eq!(dsp_kernel_memory_baseline_bytes(kernel), 0);

            dsp_kernel_initialize(kernel, 1, 1, 44100.0);
            assert!(dsp_kernel_load_wasm(kernel, wasm.as_ptr(), wasm.len() as u32));

            // After loading WASM, baseline should be set to current RSS
            let baseline = dsp_kernel_memory_baseline_bytes(kernel);
            assert!(baseline > 0, "baseline should be nonzero after WASM load, got {baseline}");

            // WASM memory should also be tracked (1 page = 64KB)
            let wasm_mem = dsp_kernel_wasm_memory_bytes(kernel);
            assert!(wasm_mem > 0, "WASM memory should be nonzero after load, got {wasm_mem}");
            assert_eq!(wasm_mem, 65536, "passthrough WAT has 1 page = 64KB");

            dsp_kernel_deinitialize(kernel);
            dsp_kernel_destroy(kernel);
        }
    }

    #[test]
    fn test_ffi_memory_baseline_resets_on_new_load() {
        let wasm = passthrough_wasm_bytes();
        let kernel = dsp_kernel_create();
        unsafe {
            dsp_kernel_initialize(kernel, 1, 1, 44100.0);
            assert!(dsp_kernel_load_wasm(kernel, wasm.as_ptr(), wasm.len() as u32));
            let baseline1 = dsp_kernel_memory_baseline_bytes(kernel);

            // Load again — baseline should be updated
            assert!(dsp_kernel_load_wasm(kernel, wasm.as_ptr(), wasm.len() as u32));
            let baseline2 = dsp_kernel_memory_baseline_bytes(kernel);

            // Both should be nonzero; they may differ slightly due to allocations
            assert!(baseline1 > 0);
            assert!(baseline2 > 0);

            dsp_kernel_deinitialize(kernel);
            dsp_kernel_destroy(kernel);
        }
    }

    #[test]
    fn test_ffi_wasm_memory_grows_with_memory_grow() {
        // WAT module that calls memory.grow(1) each process() call
        let wat = r#"
            (module
              (memory (export "memory") 1)
              (func (export "get_block_info_ptr") (result i32) (i32.const 16))
              (func (export "process")
                ;; Grow memory by 1 page (64KB) each call
                (drop (memory.grow (i32.const 1)))
              )
            )
        "#;
        let wasm = wat::parse_str(wat).expect("WAT parse failed");
        let kernel = dsp_kernel_create();

        unsafe {
            dsp_kernel_initialize(kernel, 1, 1, 44100.0);
            assert!(dsp_kernel_load_wasm(kernel, wasm.as_ptr(), wasm.len() as u32));

            let initial_wasm_mem = dsp_kernel_wasm_memory_bytes(kernel);
            assert_eq!(initial_wasm_mem, 65536, "initial: 1 page = 64KB");

            // Process a few times — each call should grow by 64KB
            let input: [f32; 4] = [0.0; 4];
            let mut output: [f32; 4] = [0.0; 4];
            let ip: *const f32 = input.as_ptr();
            let op: *mut f32 = output.as_mut_ptr();

            for i in 1..=5 {
                dsp_kernel_process(kernel, &ip, &op, 1, 4);
                let mem = dsp_kernel_wasm_memory_bytes(kernel);
                let expected = 65536 * (1 + i as u64);
                assert_eq!(mem, expected, "after {i} process calls, expected {expected} bytes, got {mem}");
            }

            dsp_kernel_deinitialize(kernel);
            dsp_kernel_destroy(kernel);
        }
    }

    #[test]
    fn test_ffi_wasm_memory_zero_for_no_backend() {
        let kernel = dsp_kernel_create();
        unsafe {
            dsp_kernel_initialize(kernel, 1, 1, 44100.0);

            // No backend loaded — process should be passthrough, WASM memory stays 0
            let input: [f32; 4] = [1.0; 4];
            let mut output: [f32; 4] = [0.0; 4];
            let ip: *const f32 = input.as_ptr();
            let op: *mut f32 = output.as_mut_ptr();
            dsp_kernel_process(kernel, &ip, &op, 1, 4);

            assert_eq!(dsp_kernel_wasm_memory_bytes(kernel), 0);

            dsp_kernel_deinitialize(kernel);
            dsp_kernel_destroy(kernel);
        }
    }

    #[test]
    fn test_ffi_param_names_json_wasm_without_names() {
        // Load a WASM module that does NOT export get_param_names_json
        let wat = r#"
            (module
              (memory (export "memory") 1)
              (func (export "get_block_info_ptr") (result i32) (i32.const 16))
              (func (export "process"))
            )
        "#;
        let wasm = wat::parse_str(wat).expect("WAT parse failed");

        let kernel = dsp_kernel_create();
        unsafe {
            let loaded = dsp_kernel_load_wasm(kernel, wasm.as_ptr(), wasm.len() as u32);
            assert!(loaded);

            let ptr = dsp_kernel_param_names_json(kernel);
            assert!(ptr.is_null(), "WASM without param names should return null");

            dsp_kernel_destroy(kernel);
        }
    }

    // --- sample_rate validation tests ---

    /// Zero sample rate must be rejected — kernel sample_rate stays at its default 44100.
    #[test]
    fn test_ffi_initialize_zero_sample_rate_rejected() {
        let kernel = dsp_kernel_create();
        unsafe {
            // Prime with a valid rate first so we have a known baseline.
            dsp_kernel_initialize(kernel, 2, 2, 44100.0);
            // Zero is invalid — initialize() must be a no-op.
            dsp_kernel_initialize(kernel, 2, 2, 0.0);
            // demo_seconds_remaining should still be finite (not NaN/Inf).
            let rem = dsp_kernel_demo_seconds_remaining(kernel, 44100.0);
            assert!(rem.is_finite(), "demo_seconds_remaining should be finite after zero-sr rejection, got {rem}");
            dsp_kernel_destroy(kernel);
        }
    }

    /// NaN sample rate must be rejected.
    #[test]
    fn test_ffi_initialize_nan_sample_rate_rejected() {
        let kernel = dsp_kernel_create();
        unsafe {
            dsp_kernel_initialize(kernel, 2, 2, 44100.0);
            dsp_kernel_initialize(kernel, 2, 2, f64::NAN);
            let rem = dsp_kernel_demo_seconds_remaining(kernel, 44100.0);
            assert!(rem.is_finite(), "demo_seconds_remaining should be finite after NaN-sr rejection, got {rem}");
            dsp_kernel_destroy(kernel);
        }
    }

    /// Negative sample rate must be rejected.
    #[test]
    fn test_ffi_initialize_negative_sample_rate_rejected() {
        let kernel = dsp_kernel_create();
        unsafe {
            dsp_kernel_initialize(kernel, 2, 2, 44100.0);
            dsp_kernel_initialize(kernel, 2, 2, -48000.0);
            let rem = dsp_kernel_demo_seconds_remaining(kernel, 44100.0);
            assert!(rem.is_finite(), "demo_seconds_remaining should be finite after negative-sr rejection, got {rem}");
            dsp_kernel_destroy(kernel);
        }
    }

    /// `dsp_kernel_process_with_sidechain` with `connected=false` and a
    /// null sidechain pointer must produce identical output to the
    /// legacy `dsp_kernel_process` entry point. Pins backwards
    /// compatibility: every existing preset goes through this path
    /// after the AU starts always advertising a second bus.
    #[test]
    fn test_ffi_process_with_sidechain_disconnected_matches_legacy() {
        let kernel_legacy = dsp_kernel_create();
        let kernel_sc = dsp_kernel_create();
        unsafe {
            dsp_kernel_initialize(kernel_legacy, 1, 1, 44100.0);
            dsp_kernel_initialize(kernel_sc, 1, 1, 44100.0);

            let input: [f32; 8] = [0.1, -0.2, 0.3, -0.4, 0.5, -0.6, 0.7, -0.8];
            let mut out_legacy: [f32; 8] = [0.0; 8];
            let mut out_sc: [f32; 8] = [0.0; 8];
            let ip: *const f32 = input.as_ptr();
            let op_legacy: *mut f32 = out_legacy.as_mut_ptr();
            let op_sc: *mut f32 = out_sc.as_mut_ptr();

            dsp_kernel_process(kernel_legacy, &ip, &op_legacy, 1, 8);
            dsp_kernel_process_with_sidechain(
                kernel_sc, &ip, &op_sc, 1, 8,
                std::ptr::null(), 0, false,
            );

            assert_eq!(out_legacy, out_sc, "disconnected sidechain path must match legacy");
            dsp_kernel_destroy(kernel_legacy);
            dsp_kernel_destroy(kernel_sc);
        }
    }

    /// `dsp_kernel_process_with_sidechain` with `connected=true` and a
    /// valid sidechain buffer must still produce passthrough on the
    /// main bus when no backend is loaded — sidechain is detection-
    /// only by convention; the kernel doesn't mix it into the output.
    #[test]
    fn test_ffi_process_with_sidechain_connected_passthrough() {
        let kernel = dsp_kernel_create();
        unsafe {
            dsp_kernel_initialize(kernel, 1, 1, 44100.0);

            let input: [f32; 4] = [0.1, 0.2, 0.3, 0.4];
            let sidechain: [f32; 4] = [0.9, -0.9, 0.9, -0.9];
            let mut output: [f32; 4] = [0.0; 4];
            let ip: *const f32 = input.as_ptr();
            let scp: *const f32 = sidechain.as_ptr();
            let op: *mut f32 = output.as_mut_ptr();

            dsp_kernel_process_with_sidechain(
                kernel, &ip, &op, 1, 4,
                &scp, 1, true,
            );
            // Output should mirror input; sidechain audio must not leak
            // into the main bus on the no-backend passthrough path.
            assert_eq!(output, [0.1, 0.2, 0.3, 0.4]);
            dsp_kernel_destroy(kernel);
        }
    }

    /// Valid boundary sample rates must be accepted.
    #[test]
    fn test_ffi_initialize_valid_boundary_sample_rates() {
        for &sr in &[8000.0f64, 44100.0, 48000.0, 96000.0, 192000.0, 384000.0] {
            let kernel = dsp_kernel_create();
            unsafe {
                dsp_kernel_initialize(kernel, 2, 2, sr);
                let rem = dsp_kernel_demo_seconds_remaining(kernel, sr);
                assert!(rem.is_finite(), "demo_seconds_remaining should be finite for sr={sr}, got {rem}");
                dsp_kernel_destroy(kernel);
            }
        }
    }
}
