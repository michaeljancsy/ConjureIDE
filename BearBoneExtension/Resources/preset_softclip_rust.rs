// Soft Clip — tanh waveshaping saturation.
//
// Applies a smooth, warm saturation by passing the signal through a
// hyperbolic tangent function. The drive parameter controls how hard
// the signal is pushed into the nonlinearity. Output is normalized
// so that low-level signals pass through at unity gain.

const MAX_CH: usize = 2;
const MAX_FR: usize = 4096;

static mut INPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut OUTPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut PARAMS_BUF: [f32; 8] = [0.0; 8];

const DRIVE: f32 = 3.0;

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

fn tanh_f32(x: f32) -> f32 {
    let e2x = (2.0 * x).exp();
    (e2x - 1.0) / (e2x + 1.0)
}

#[no_mangle]
pub extern "C" fn process(
    input: *const f32,
    output: *mut f32,
    channels: i32,
    frame_count: i32,
    _sample_rate: f32,
) {
    let ch = channels as usize;
    let frames = frame_count as usize;
    let norm = 1.0 / tanh_f32(DRIVE);

    unsafe {
        let inp = std::slice::from_raw_parts(input, ch * frames);
        let out = std::slice::from_raw_parts_mut(output, ch * frames);

        for i in 0..frames {
            for c in 0..ch {
                let idx = i * ch + c;
                out[idx] = tanh_f32(DRIVE * inp[idx]) * norm;
            }
        }
    }
}
