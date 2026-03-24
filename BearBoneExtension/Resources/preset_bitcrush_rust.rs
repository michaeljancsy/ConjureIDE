// Bitcrush — bit depth reduction and sample rate reduction.
//
// Applies two lo-fi effects in series:
// 1. Bit depth reduction: quantizes the signal to fewer amplitude levels,
//    producing a gritty, digital distortion.
// 2. Sample rate reduction: holds every Nth sample, discarding the rest,
//    which introduces aliasing artifacts and a characteristic stepped sound.
//
// Params:
//   0 (Bit Depth):  Quantization depth — 1 to 16 bits
//   1 (Downsample): Sample rate reduction factor — 1x to 16x

const MAX_CH: usize = 2;
const MAX_FR: usize = 4096;

static mut INPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut OUTPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut PARAMS_BUF: [f32; 16] = [0.0; 16];

// Parameter indices
const BIT_DEPTH: usize = 0;  // 1–16 bits
const DOWNSAMPLE: usize = 1; // 1–16x

// Persistent held sample per channel for sample-rate reduction
static mut HELD: [f32; MAX_CH] = [0.0; MAX_CH];

static METADATA: &str = r#"[{"name":"Bit Depth","min":1.0,"max":16.0,"unit":"bits","default":16.0},{"name":"Downsample","min":1.0,"max":16.0,"unit":"x","default":1.0}]"#;

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
        let bit_depth = PARAMS_BUF[BIT_DEPTH] as i32;       // truncate to match Python's int()
        let downsample = PARAMS_BUF[DOWNSAMPLE] as usize;  // truncate to match Python's int()
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
