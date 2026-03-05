// Stereo Width — mid/side stereo width control.
//
// Encodes the stereo signal into mid (L+R) and side (L-R) components,
// scales the side component by the width factor, then decodes back to
// L/R. At WIDTH=0 the output is mono, at WIDTH=1 the signal is
// unchanged, and above 1.0 the stereo image is exaggerated.
// For mono input, the signal passes through unchanged.

const MAX_CH: usize = 2;
const MAX_FR: usize = 4096;

static mut INPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut OUTPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut PARAMS_BUF: [f32; 8] = [0.0; 8];

const WIDTH: f32 = 1.5;

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
            let side_scaled = side * WIDTH;

            // Decode back to L/R
            out[i] = mid + side_scaled;
            out[frames + i] = mid - side_scaled;
        }
    }
}
