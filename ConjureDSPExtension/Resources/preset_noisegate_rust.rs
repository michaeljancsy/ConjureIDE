// Noise Gate — silences signal below a threshold.
//
// Monitors the peak level across all channels. When the level drops
// below the threshold, the gate closes (attenuates to silence) after
// a hold period. Attack and release control how quickly the gate
// opens and closes. The hold time prevents the gate from chattering
// on signals that hover near the threshold.
//
// Params:
//   0 (Threshold): Gate threshold — -80 to -20 dB
//   1 (Attack):    Attack time — 0.1 to 10 ms
//   2 (Release):   Release time — 10 to 500 ms
//   3 (Hold):      Hold time — 0 to 100 ms

const MAX_CH: usize = 2;
const MAX_FR: usize = 4096;

static mut INPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut OUTPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut PARAMS_BUF: [f32; 16] = [0.0; 16];

// Parameter indices
const THRESHOLD: usize = 0; // -80–-20 dB
const ATTACK: usize = 1;    // 0.1–10 ms
const RELEASE: usize = 2;   // 10–500 ms
const HOLD: usize = 3;      // 0–100 ms

// Persistent state
// Use f64 to match Python's float64 precision in the envelope feedback loop.
static mut ENVELOPE: f64 = 0.0;
static mut HOLD_COUNTER: i32 = 0;

static METADATA: &str = r#"[{"name":"Threshold","min":-80.0,"max":-20.0,"unit":"dB","default":-40.0},{"name":"Attack","min":0.1,"max":10.0,"unit":"ms","default":1.0},{"name":"Release","min":10.0,"max":500.0,"unit":"ms","default":100.0},{"name":"Hold","min":0.0,"max":100.0,"unit":"ms","default":10.0}]"#;

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
    let sr = sample_rate as f64;

    unsafe {
        let threshold_db = PARAMS_BUF[THRESHOLD] as f64;
        let attack_ms = PARAMS_BUF[ATTACK] as f64;
        let release_ms = PARAMS_BUF[RELEASE] as f64;
        let hold_ms = PARAMS_BUF[HOLD] as f64;

        let threshold = (10.0_f64).powf(threshold_db / 20.0);
        let attack_coeff = (-1.0 / (attack_ms * 0.001 * sr)).exp();
        let release_coeff = (-1.0 / (release_ms * 0.001 * sr)).exp();
        let hold_samples = (hold_ms * 0.001 * sr) as i32;
        let inp = std::slice::from_raw_parts(input, ch * frames);
        let out = std::slice::from_raw_parts_mut(output, ch * frames);
        let mut env = ENVELOPE;
        let mut hold = HOLD_COUNTER;

        for i in 0..frames {
            // Peak detect across all channels
            let mut peak: f64 = 0.0;
            for c in 0..ch {
                let abs_val = (inp[c * frames + i] as f64).abs();
                if abs_val > peak {
                    peak = abs_val;
                }
            }

            if peak > threshold {
                // Gate open: envelope approaches 1.0
                env = attack_coeff * env + (1.0 - attack_coeff);
                hold = hold_samples;
            } else if hold > 0 {
                // Hold: maintain current envelope
                hold -= 1;
            } else {
                // Release: envelope approaches 0.0
                env = release_coeff * env;
            }

            for c in 0..ch {
                let idx = c * frames + i;
                out[idx] = (inp[idx] as f64 * env) as f32;
            }
        }

        ENVELOPE = env;
        HOLD_COUNTER = hold;
    }
}
