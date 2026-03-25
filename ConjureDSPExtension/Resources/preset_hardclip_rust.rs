// Hard Clip — hard clipping distortion.
//
// Amplifies the signal by the drive amount, then clips any values
// exceeding +/-1.0. Produces a harsh, buzzy distortion with odd harmonics.
// Higher drive values push more of the signal into clipping.
//
// Params:
//   0 (Drive): Amplification factor — 1.0 to 20.0

const MAX_CH: usize = 2;
const MAX_FR: usize = 4096;

static mut INPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut OUTPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut PARAMS_BUF: [f32; 16] = [0.0; 16];

// Parameter indices
const DRIVE: usize = 0; // 1.0–20.0

static METADATA: &str = r#"[{"name":"Drive","min":1.0,"max":20.0,"unit":"","default":5.0}]"#;

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
        let inp = std::slice::from_raw_parts(input, ch * frames);
        let out = std::slice::from_raw_parts_mut(output, ch * frames);

        for c in 0..ch {
            for i in 0..frames {
                let idx = c * frames + i;
                let driven = drive * inp[idx];
                out[idx] = if driven > 1.0 {
                    1.0
                } else if driven < -1.0 {
                    -1.0
                } else {
                    driven
                };
            }
        }
    }
}
