// DC Blocker — removes DC offset from the signal.
//
// Implements a first-order high-pass filter:
//     y[n] = x[n] - x[n-1] + R * y[n-1]
// where R controls the cutoff frequency (closer to 1.0 = lower cutoff).
// The cutoff parameter sets the -3dB frequency in Hz; R is computed
// from the sample rate using the exact exponential formula.
//
// Params:
//   0 (Cutoff): High-pass cutoff — 4 to 70 Hz

const MAX_CH: usize = 2;
const MAX_FR: usize = 4096;

static mut INPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut OUTPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut PARAMS_BUF: [f32; 16] = [0.0; 16];

// Parameter indices
const CUTOFF: usize = 0; // 4–70 Hz

// Persistent state per channel: [prev_x, prev_y]
// Use f64 to match Python's float64 precision — f32 accumulation
// in the feedback loop (R * prev_y) causes audible rounding drift.
static mut PREV_X: [f64; MAX_CH] = [0.0; MAX_CH];
static mut PREV_Y: [f64; MAX_CH] = [0.0; MAX_CH];

static METADATA: &str = r#"[{"name":"Cutoff","min":4.0,"max":70.0,"unit":"Hz","default":4.0}]"#;

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
    sample_rate: f32,
) {
    let ch = channels as usize;
    let frames = frame_count as usize;

    unsafe {
        let cutoff_hz = PARAMS_BUF[CUTOFF] as f64;
        let r = (-2.0 * core::f64::consts::PI * cutoff_hz / (sample_rate as f64)).exp();
        let inp = std::slice::from_raw_parts(input, ch * frames);
        let out = std::slice::from_raw_parts_mut(output, ch * frames);

        for c in 0..ch {
            let mut px = PREV_X[c];
            let mut py = PREV_Y[c];

            for i in 0..frames {
                let idx = c * frames + i;
                let x = inp[idx] as f64;
                py = x - px + r * py;
                px = x;
                out[idx] = py as f32;
            }

            PREV_X[c] = px;
            PREV_Y[c] = py;
        }
    }
}
