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

// Bitcrush parameters
const BIT_DEPTH: i32 = 8;   // Reduce to this many bits (1-16)
const DOWNSAMPLE: usize = 4; // Keep every Nth sample, hold others

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
///
/// For each sample: first quantizes the amplitude to 2^BIT_DEPTH discrete levels
/// (bit crushing), then applies sample-and-hold at a 1/DOWNSAMPLE rate (sample
/// rate reduction). The held sample state persists across callbacks for seamless
/// processing. DAW-automatable parameters are available in PARAMS_BUF[0..8] but
/// unused by this preset.
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
    let levels = (1 << BIT_DEPTH) as f32;

    unsafe {
        let inp = std::slice::from_raw_parts(input, ch * frames);
        let out = std::slice::from_raw_parts_mut(output, ch * frames);

        for i in 0..frames {
            for c in 0..ch {
                let idx = c * frames + i;
                // Bit depth reduction: quantize to fewer levels
                let crushed = (inp[idx] * levels).round() / levels;
                // Sample rate reduction: hold every Nth sample
                if i % DOWNSAMPLE == 0 {
                    HELD[c] = crushed;
                }
                out[idx] = HELD[c];
            }
        }
    }
}
