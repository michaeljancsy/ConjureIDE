// Limiter — brick-wall peak limiter.
//
// Prevents the signal from exceeding the threshold using a fast-attack
// envelope follower. When the peak level exceeds the threshold, gain
// is reduced so the output stays at the threshold. The ultra-fast attack
// (0.1 ms) catches transients; the slower release allows natural decay.
// Unlike a compressor, the ratio is effectively infinite — nothing
// passes above the ceiling.

const MAX_CH: usize = 2;
const MAX_FR: usize = 4096;

static mut INPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut OUTPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut PARAMS_BUF: [f32; 8] = [0.0; 8];

const THRESHOLD_DB: f64 = -3.0;
const ATTACK_MS: f64 = 0.1;
const RELEASE_MS: f64 = 100.0;

// Persistent envelope follower state
// Use f64 to match Python's float64 precision in the envelope feedback loop.
static mut ENVELOPE: f64 = 0.0;

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
    let threshold = (10.0_f64).powf(THRESHOLD_DB / 20.0);
    let attack_coeff = (-1.0 / (ATTACK_MS * 0.001 * sr)).exp();
    let release_coeff = (-1.0 / (RELEASE_MS * 0.001 * sr)).exp();

    unsafe {
        let inp = std::slice::from_raw_parts(input, ch * frames);
        let out = std::slice::from_raw_parts_mut(output, ch * frames);
        let mut env = ENVELOPE;

        for i in 0..frames {
            // Peak detect across all channels
            let mut peak: f64 = 0.0;
            for c in 0..ch {
                let abs_val = (inp[c * frames + i] as f64).abs();
                if abs_val > peak {
                    peak = abs_val;
                }
            }

            // Envelope follower
            if peak > env {
                env = attack_coeff * env + (1.0 - attack_coeff) * peak;
            } else {
                env = release_coeff * env + (1.0 - release_coeff) * peak;
            }

            // Gain reduction: clamp output to threshold
            // Truncate gain to f32 to match Python's np.float32 gain array.
            let gain: f32 = if env > threshold {
                (threshold / env) as f32
            } else {
                1.0
            };

            for c in 0..ch {
                let idx = c * frames + i;
                out[idx] = inp[idx] * gain;
            }
        }

        ENVELOPE = env;
    }
}
