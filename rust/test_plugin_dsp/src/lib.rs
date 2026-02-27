mod kernel;
mod params;

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
            assert_eq!(dsp_kernel_get_parameter(kernel, 42), 0.0);
            dsp_kernel_set_parameter(kernel, 42, 1.0);
            assert_eq!(dsp_kernel_get_parameter(kernel, 42), 0.0);
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
}
