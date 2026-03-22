mod backend;
mod kernel;
mod license;
mod params;
mod python_backend;
mod ring_buffer;
mod wasm_backend;

use kernel::DSPKernel;
use std::ffi::CStr;
use std::os::raw::c_char;

/// Opaque handle to the DSP kernel. Swift sees this as `OpaquePointer`.
pub type DSPKernelRef = *mut DSPKernel;

#[no_mangle]
pub extern "C" fn dsp_kernel_create() -> DSPKernelRef {
    Box::into_raw(Box::new(DSPKernel::new()))
}

/// # Safety
/// `kernel` must be a valid pointer returned by `dsp_kernel_create`.
#[no_mangle]
pub unsafe extern "C" fn dsp_kernel_destroy(kernel: DSPKernelRef) {
    if !kernel.is_null() {
        drop(Box::from_raw(kernel));
    }
}

/// # Safety
/// `kernel` must be a valid pointer returned by `dsp_kernel_create`.
#[no_mangle]
pub unsafe extern "C" fn dsp_kernel_initialize(
    kernel: DSPKernelRef,
    input_channel_count: i32,
    output_channel_count: i32,
    sample_rate: f64,
) {
    (*kernel).initialize(input_channel_count, output_channel_count, sample_rate);
}

/// # Safety
/// `kernel` must be a valid pointer returned by `dsp_kernel_create`.
#[no_mangle]
pub unsafe extern "C" fn dsp_kernel_deinitialize(kernel: DSPKernelRef) {
    (*kernel).deinitialize();
}

/// # Safety
/// `kernel` must be a valid pointer returned by `dsp_kernel_create`.
#[no_mangle]
pub unsafe extern "C" fn dsp_kernel_set_bypassed(kernel: DSPKernelRef, bypass: bool) {
    (*kernel).set_bypassed(bypass);
}

/// # Safety
/// `kernel` must be a valid pointer returned by `dsp_kernel_create`.
#[no_mangle]
pub unsafe extern "C" fn dsp_kernel_is_bypassed(kernel: DSPKernelRef) -> bool {
    (*kernel).is_bypassed()
}

/// # Safety
/// `kernel` must be a valid pointer returned by `dsp_kernel_create`.
#[no_mangle]
pub unsafe extern "C" fn dsp_kernel_set_parameter(
    kernel: DSPKernelRef,
    address: u64,
    value: f32,
) {
    (*kernel).set_parameter(address, value);
}

/// # Safety
/// `kernel` must be a valid pointer returned by `dsp_kernel_create`.
#[no_mangle]
pub unsafe extern "C" fn dsp_kernel_get_parameter(kernel: DSPKernelRef, address: u64) -> f32 {
    (*kernel).get_parameter(address)
}

/// # Safety
/// `kernel` must be a valid pointer returned by `dsp_kernel_create`.
#[no_mangle]
pub unsafe extern "C" fn dsp_kernel_get_max_frames(kernel: DSPKernelRef) -> u32 {
    (*kernel).maximum_frames_to_render()
}

/// # Safety
/// `kernel` must be a valid pointer returned by `dsp_kernel_create`.
#[no_mangle]
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
#[no_mangle]
pub unsafe extern "C" fn dsp_kernel_process(
    kernel: DSPKernelRef,
    input_buffers: *const *const f32,
    output_buffers: *const *mut f32,
    channel_count: u32,
    frame_count: u32,
) {
    (*kernel).process(input_buffers, output_buffers, channel_count, frame_count);
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
#[no_mangle]
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

/// Load a WASM module for DSP processing.
///
/// The module must export a `process` function with signature
/// `(input_ptr: i32, output_ptr: i32, channels: i32, frame_count: i32, sample_rate: f32)`
/// and a `memory` (linear memory).
///
/// Returns true on success, false on error (check `dsp_kernel_last_error`).
///
/// # Safety
/// - `kernel` must be a valid pointer returned by `dsp_kernel_create`.
/// - `wasm_bytes` must point to `len` valid bytes of a WASM module.
#[no_mangle]
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

/// Benchmark the process function.
/// Returns the max execution time in seconds over 5 runs, or -1.0 if no script is loaded.
///
/// # Safety
/// `kernel` must be a valid pointer returned by `dsp_kernel_create`.
#[no_mangle]
pub unsafe extern "C" fn dsp_kernel_benchmark_process(kernel: DSPKernelRef) -> f64 {
    (*kernel).benchmark_process().unwrap_or(-1.0)
}

/// Returns the last error message as a null-terminated C string.
/// Returns null if no error. The pointer is valid until the next call to this function or destroy.
///
/// # Safety
/// `kernel` must be a valid pointer returned by `dsp_kernel_create`.
#[no_mangle]
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

/// Returns script-declared parameter names as a null-terminated JSON C string,
/// e.g. `{"0":"Cutoff","1":"Resonance"}`.
/// Returns null if the loaded script does not declare parameter names.
/// The pointer is valid until the next script load or kernel destroy.
///
/// # Safety
/// `kernel` must be a valid pointer returned by `dsp_kernel_create`.
#[no_mangle]
pub unsafe extern "C" fn dsp_kernel_param_names_json(kernel: DSPKernelRef) -> *const c_char {
    (*kernel).param_names_json_ptr()
}

/// Enable or disable audio capture for spectrogram visualization.
/// When disabled, ring buffers are not written to (saves CPU on audio thread).
///
/// # Safety
/// `kernel` must be a valid pointer returned by `dsp_kernel_create`.
#[no_mangle]
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
#[no_mangle]
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
#[no_mangle]
pub unsafe extern "C" fn dsp_kernel_read_output_ring(
    kernel: DSPKernelRef,
    out: *mut f32,
    max_samples: u32,
) -> u32 {
    let output = std::slice::from_raw_parts_mut(out, max_samples as usize);
    (*kernel).read_output_ring(output) as u32
}

/// Verify a license serial key and set the kernel's licensed state.
/// Returns true if the license is valid.
///
/// # Safety
/// - `kernel` must be a valid pointer returned by `dsp_kernel_create`.
/// - `serial` must be a valid null-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn dsp_kernel_verify_license(
    kernel: DSPKernelRef,
    serial: *const c_char,
) -> bool {
    let serial_str = match CStr::from_ptr(serial).to_str() {
        Ok(s) => s,
        Err(_) => return false,
    };
    match crate::license::verify_license(serial_str) {
        Ok(_payload) => {
            (*kernel).set_licensed(true);
            true
        }
        Err(e) => {
            (*kernel).last_error = Some(format!("License verification failed: {}", e));
            false
        }
    }
}

/// Check if the kernel has a valid license.
///
/// # Safety
/// `kernel` must be a valid pointer returned by `dsp_kernel_create`.
#[no_mangle]
pub unsafe extern "C" fn dsp_kernel_is_licensed(kernel: DSPKernelRef) -> bool {
    (*kernel).is_licensed()
}

/// Get the remaining demo time in seconds at the given sample rate.
/// Returns infinity if licensed.
///
/// # Safety
/// `kernel` must be a valid pointer returned by `dsp_kernel_create`.
#[no_mangle]
pub unsafe extern "C" fn dsp_kernel_demo_seconds_remaining(
    kernel: DSPKernelRef,
    sample_rate: f64,
) -> f64 {
    (*kernel).demo_seconds_remaining(sample_rate)
}

/// Set the licensed state directly (for restoring from persisted license).
///
/// # Safety
/// `kernel` must be a valid pointer returned by `dsp_kernel_create`.
#[no_mangle]
pub unsafe extern "C" fn dsp_kernel_set_licensed(kernel: DSPKernelRef, licensed: bool) {
    (*kernel).set_licensed(licensed);
}

/// Reset the demo sample counter, giving another 60 seconds of demo time.
///
/// # Safety
/// `kernel` must be a valid pointer returned by `dsp_kernel_create`.
#[no_mangle]
pub unsafe extern "C" fn dsp_kernel_reset_demo(kernel: DSPKernelRef) {
    (*kernel).reset_demo();
}

/// Return a pointer to the embedded Ed25519 public key (32 bytes).
/// The pointer is valid for the lifetime of the process (static data).
#[no_mangle]
pub extern "C" fn dsp_kernel_public_key() -> *const u8 {
    license::public_key_bytes().as_ptr()
}

#[cfg(test)]
mod tests {
    use super::*;

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

            // All 8 parameters
            for addr in 0..8u64 {
                dsp_kernel_set_parameter(kernel, addr, (addr + 1) as f32 * 0.1);
            }
            for addr in 0..8u64 {
                let expected = (addr + 1) as f32 * 0.1;
                let actual = dsp_kernel_get_parameter(kernel, addr);
                assert!((actual - expected).abs() < 1e-6, "addr={} expected={} got={}", addr, expected, actual);
            }

            // Out-of-range address returns 0.0
            assert_eq!(dsp_kernel_get_parameter(kernel, 8), 0.0);
            assert_eq!(dsp_kernel_get_parameter(kernel, 9), 0.0);
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
        wat::parse_str(r#"
            (module
              (memory (export "memory") 1)
              (func (export "process") (param $in i32) (param $out i32) (param $ch i32) (param $frames i32) (param $sr f32)
                (local $i i32)
                (local $total i32)
                (local.set $total (i32.mul (local.get $ch) (local.get $frames)))
                (block $break
                  (loop $loop
                    (br_if $break (i32.ge_u (local.get $i) (local.get $total)))
                    (f32.store
                      (i32.add (local.get $out) (i32.mul (local.get $i) (i32.const 4)))
                      (f32.load (i32.add (local.get $in) (i32.mul (local.get $i) (i32.const 4))))
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
            let remaining = dsp_kernel_demo_seconds_remaining(kernel, 48000.0);
            assert!((remaining - 60.0).abs() < 0.1);

            dsp_kernel_set_licensed(kernel, true);
            let remaining = dsp_kernel_demo_seconds_remaining(kernel, 48000.0);
            assert!(remaining.is_infinite());

            dsp_kernel_destroy(kernel);
        }
    }

    #[test]
    fn test_ffi_verify_license_invalid_serial() {
        let kernel = dsp_kernel_create();
        unsafe {
            let serial = std::ffi::CString::new("invalid.serial").unwrap();
            let result = dsp_kernel_verify_license(kernel, serial.as_ptr());
            assert!(!result);
            assert!(!dsp_kernel_is_licensed(kernel));

            // Should have set an error message
            let err = dsp_kernel_last_error(kernel);
            assert!(!err.is_null());

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
              (func (export "process")
                (param $in i32) (param $out i32) (param $ch i32) (param $frames i32) (param $sr f32)
              )
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
    fn test_ffi_param_names_json_wasm_without_names() {
        // Load a WASM module that does NOT export get_param_names_json
        let wat = r#"
            (module
              (memory (export "memory") 1)
              (func (export "process")
                (param $in i32) (param $out i32) (param $ch i32) (param $frames i32) (param $sr f32)
              )
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
}
