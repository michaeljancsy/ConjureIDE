// White Noise Generator — generates uniform white noise.
//
// Ignores the input signal and fills the output with pseudo-random
// noise using a linear congruential generator. The LCG state persists
// across callbacks for a continuous noise stream. Both Python and Rust
// implementations use the same LCG constants for identical output.
//
// Params:
//   0 (Level): Noise amplitude — 0.0 to 1.0

const MAX_CH: usize = 2;
const MAX_FR: usize = 4096;

static mut INPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut OUTPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut PARAMS_BUF: [f32; 16] = [0.0; 16];

// Parameter indices
const LEVEL: usize = 0; // 0.0–1.0

// LCG random state
static mut RNG_STATE: u32 = 12345;

static METADATA: &str = r#"[{"name":"Level","min":0.0,"max":1.0,"unit":"","default":0.5}]"#;

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

fn next_f32() -> f32 {
    unsafe {
        RNG_STATE = RNG_STATE.wrapping_mul(1664525).wrapping_add(1013904223);
        (RNG_STATE as f32) / 4294967296.0 * 2.0 - 1.0
    }
}

#[no_mangle]
pub extern "C" fn process(
    _input: *const f32,
    output: *mut f32,
    channels: i32,
    frame_count: i32,
    _sample_rate: f32,
) {
    let ch = channels as usize;
    let frames = frame_count as usize;

    unsafe {
        let out = std::slice::from_raw_parts_mut(output, ch * frames);

        let amplitude = PARAMS_BUF[LEVEL];

        for i in 0..frames {
            let sample = next_f32() * amplitude;
            for c in 0..ch {
                out[c * frames + i] = sample;
            }
        }
    }
}
