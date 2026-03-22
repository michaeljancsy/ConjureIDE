// Noise Gate — silences signal below a threshold.
//
// Monitors the peak level across all channels. When the level drops
// below the threshold, the gate closes (attenuates to silence) after
// a hold period. Attack and release control how quickly the gate
// opens and closes. The hold time prevents the gate from chattering
// on signals that hover near the threshold.

const MAX_CH: usize = 2;
const MAX_FR: usize = 4096;

static mut INPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut OUTPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut PARAMS_BUF: [f32; 8] = [0.0; 8];

// Parameters:
const THRESHOLD: usize = 0;
const ATTACK: usize = 1;
const RELEASE: usize = 2;
const HOLD: usize = 3;

// Persistent state
// Use f64 to match Python's float64 precision in the envelope feedback loop.
static mut ENVELOPE: f64 = 0.0;
static mut HOLD_COUNTER: i32 = 0;

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
    sample_rate: f32,
) {
    let ch = channels as usize;
    let frames = frame_count as usize;
    let sr = sample_rate as f64;

    unsafe {
        let threshold_db = -80.0 + PARAMS_BUF[THRESHOLD] as f64 * 60.0;  // -80 to -20 dB
        let attack_ms = 0.1 + PARAMS_BUF[ATTACK] as f64 * 9.9;           // 0.1 to 10 ms
        let release_ms = 10.0 + PARAMS_BUF[RELEASE] as f64 * 490.0;      // 10 to 500 ms
        let hold_ms = PARAMS_BUF[HOLD] as f64 * 100.0;                    // 0 to 100 ms

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
