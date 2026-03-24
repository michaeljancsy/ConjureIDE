// Passthrough — copies input audio to output unchanged.
//
// The simplest possible Rust DSP script. Each sample is copied from the input
// buffer to the output buffer with no modification.

const MAX_CH: usize = 2;
const MAX_FR: usize = 4096;

static mut INPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut OUTPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut PARAMS_BUF: [f32; 16] = [0.0; 16];

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

/// Passthrough — copies input to output unchanged.
///
/// Iterates over all channel-sequential samples (channels x frames) and copies each
/// input sample directly to the output buffer. DAW-automatable parameters are
/// available in PARAMS_BUF[0..16] but unused by this preset.
#[no_mangle]
pub extern "C" fn process(
    input: *const f32,
    output: *mut f32,
    channels: i32,
    frame_count: i32,
    _sample_rate: f32,
) {
    let n = (channels * frame_count) as usize;
    unsafe {
        let inp = std::slice::from_raw_parts(input, n);
        let out = std::slice::from_raw_parts_mut(output, n);
        for i in 0..n {
            out[i] = inp[i];
        }
    }
}
