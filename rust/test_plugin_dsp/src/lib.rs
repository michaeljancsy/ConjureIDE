mod kernel;
mod params;

use kernel::DSPKernel;

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
