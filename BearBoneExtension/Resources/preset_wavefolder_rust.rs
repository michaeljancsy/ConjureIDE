// Wavefolder — folds the waveform back when it exceeds ±1.
//
// Applies gain (drive) to the input, then uses triangle-wave wrapping
// to fold the signal back into the ±1 range. Each fold reflects the
// waveform, producing increasingly rich harmonic content as drive increases.
// Unlike clipping, wavefolding preserves energy and creates a distinctive
// metallic/buzzy timbre popular in modular synthesis.

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

        for c in 0..ch {
            for i in 0..frames {
                let idx = c * frames + i;
                let x = inp[idx] * DRIVE;
                // Triangle-wave fold: maps any value into [-1, 1]
                let t = (x + 1.0) * 0.25;
                let t = t - t.floor();
                out[idx] = 1.0 - (t * 4.0 - 2.0).abs();
            }
        }
    }
}
