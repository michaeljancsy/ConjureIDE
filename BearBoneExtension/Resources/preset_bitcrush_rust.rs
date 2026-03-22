// Bitcrush — bit depth reduction and sample rate reduction.
//
// Applies two lo-fi effects in series:
// 1. Bit depth reduction: quantizes the signal to fewer amplitude levels,
//    producing a gritty, digital distortion.
// 2. Sample rate reduction: holds every Nth sample, discarding the rest,
//    which introduces aliasing artifacts and a characteristic stepped sound.

const MAX_CH: usize = 2;
const MAX_FR: usize = 4096;

static mut INPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut OUTPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut PARAMS_BUF: [f32; 8] = [0.0; 8];

// Parameters:
const BIT_DEPTH: usize = 0;
const DOWNSAMPLE: usize = 1;

// Persistent held sample per channel for sample-rate reduction
static mut HELD: [f32; MAX_CH] = [0.0; MAX_CH];

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

/// Bitcrush — bit depth reduction and sample rate reduction.
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
        let bit_depth = (PARAMS_BUF[BIT_DEPTH] * 15.0) as i32 + 1;    // 1 to 16
        let downsample = (PARAMS_BUF[DOWNSAMPLE] * 15.0) as usize + 1; // 1 to 16
        let levels = (1 << bit_depth) as f32;

        let inp = std::slice::from_raw_parts(input, ch * frames);
        let out = std::slice::from_raw_parts_mut(output, ch * frames);

        for i in 0..frames {
            for c in 0..ch {
                let idx = c * frames + i;
                // Bit depth reduction: quantize to fewer levels
                let crushed = (inp[idx] * levels).round() / levels;
                // Sample rate reduction: hold every Nth sample
                if i % downsample == 0 {
                    HELD[c] = crushed;
                }
                out[idx] = HELD[c];
            }
        }
    }
}
