// Soft Clip — tanh waveshaping saturation.
//
// Applies a smooth, warm saturation by passing the signal through a
// hyperbolic tangent function. The drive parameter controls how hard
// the signal is pushed into the nonlinearity. Output is normalized
// so that low-level signals pass through at unity gain.
//
// Params:
//   0 (Drive): Saturation amount — 1.0 to 15.0

const MAX_CH: usize = 2;
const MAX_FR: usize = 4096;

static mut INPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut OUTPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut PARAMS_BUF: [f32; 16] = [0.0; 16];

// Parameter indices
const DRIVE: usize = 0; // 1.0–15.0

static METADATA: &str = r#"[{"name":"Drive","min":1.0,"max":15.0,"unit":"","default":3.0}]"#;

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
pub extern "C" fn get_param_metadata_ptr() -> i32 {
    METADATA.as_ptr() as i32
}

#[no_mangle]
pub extern "C" fn get_param_metadata_len() -> i32 {
    METADATA.len() as i32
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

    unsafe {
        let drive = PARAMS_BUF[DRIVE];
        let norm = 1.0 / tanh_f32(drive);
        let inp = std::slice::from_raw_parts(input, ch * frames);
        let out = std::slice::from_raw_parts_mut(output, ch * frames);

        for c in 0..ch {
            for i in 0..frames {
                let idx = c * frames + i;
                out[idx] = tanh_f32(drive * inp[idx]) * norm;
            }
        }
    }
}
