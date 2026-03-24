// Gain + Pan — volume control with stereo panning.
//
// Applies gain and constant-power panning to the signal.
//
// Params:
//   0 (Gain): Volume — -24 to +12 dB
//   1 (Pan):  Stereo position — 0.0 = hard left, 0.5 = center, 1.0 = hard right

const MAX_CH: usize = 2;
const MAX_FR: usize = 4096;

static mut INPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut OUTPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut PARAMS_BUF: [f32; 16] = [0.0; 16];

// Parameter indices
const GAIN: usize = 0; // -24–+12 dB
const PAN: usize = 1;  // 0.0–1.0

static METADATA: &str = r#"[{"name":"Gain","min":-24.0,"max":12.0,"unit":"dB","default":0.0},{"name":"Pan","min":0.0,"max":1.0,"unit":"","default":0.5}]"#;

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
    let half_pi = core::f32::consts::PI * 0.5;

    unsafe {
        let gain_db = PARAMS_BUF[GAIN];
        let pan = PARAMS_BUF[PAN];

        let gain = (10.0_f32).powf(gain_db / 20.0);
        let inp = std::slice::from_raw_parts(input, ch * frames);
        let out = std::slice::from_raw_parts_mut(output, ch * frames);

        if ch == 1 {
            for i in 0..frames {
                out[i] = inp[i] * gain;
            }
        } else {
            let left_gain = gain * (pan * half_pi).cos();
            let right_gain = gain * (pan * half_pi).sin();
            for i in 0..frames {
                out[i] = inp[i] * left_gain;
                out[frames + i] = inp[frames + i] * right_gain;
            }
        }
    }
}
