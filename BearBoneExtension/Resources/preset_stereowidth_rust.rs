// Stereo Width — mid/side stereo width control.
//
// Encodes the stereo signal into mid (L+R) and side (L-R) components,
// scales the side component by the width factor, then decodes back to
// L/R. At WIDTH=0 the output is mono, at WIDTH=1 the signal is
// unchanged, and above 1.0 the stereo image is exaggerated.
// For mono input, the signal passes through unchanged.
//
// Params:
//   0 (Width): Stereo width — 0.0 to 2.0

const MAX_CH: usize = 2;
const MAX_FR: usize = 4096;

static mut INPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut OUTPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut PARAMS_BUF: [f32; 16] = [0.0; 16];

// Parameter indices
const WIDTH: usize = 0; // 0.0–2.0

static METADATA: &str = r#"[{"name":"Width","min":0.0,"max":2.0,"unit":"","default":1.0}]"#;

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
        let width = PARAMS_BUF[WIDTH];
        let inp = std::slice::from_raw_parts(input, ch * frames);
        let out = std::slice::from_raw_parts_mut(output, ch * frames);

        if ch < 2 {
            // Mono: passthrough
            for i in 0..frames {
                out[i] = inp[i];
            }
            return;
        }

        for i in 0..frames {
            let left = inp[i];
            let right = inp[frames + i];

            // Encode to mid/side
            let mid = (left + right) * 0.5;
            let side = (left - right) * 0.5;

            // Scale side component
            let side_scaled = side * width;

            // Decode back to L/R
            out[i] = mid + side_scaled;
            out[frames + i] = mid - side_scaled;
        }
    }
}
