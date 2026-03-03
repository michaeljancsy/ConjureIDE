// Compressor — dynamic range compression with envelope follower.

const MAX_CH: usize = 2;
const MAX_FR: usize = 4096;

static mut INPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut OUTPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];

// Compressor parameters
const THRESHOLD_DB: f32 = -20.0; // Level above which compression kicks in
const RATIO: f32 = 4.0;          // Compression ratio (4:1)
const ATTACK_MS: f32 = 5.0;      // Attack time in milliseconds
const RELEASE_MS: f32 = 50.0;    // Release time in milliseconds
const MAKEUP_DB: f32 = 6.0;      // Makeup gain in dB

// Persistent envelope follower state
static mut ENVELOPE: f32 = 0.0;

#[no_mangle]
pub extern "C" fn get_input_ptr() -> i32 {
    unsafe { INPUT_BUF.as_ptr() as i32 }
}

#[no_mangle]
pub extern "C" fn get_output_ptr() -> i32 {
    unsafe { OUTPUT_BUF.as_ptr() as i32 }
}

fn db_to_lin(db: f32) -> f32 {
    (10.0_f32).powf(db / 20.0)
}

fn lin_to_db(lin: f32) -> f32 {
    20.0 * (lin + 1e-30).log10()
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
    let threshold = db_to_lin(THRESHOLD_DB);
    let makeup = db_to_lin(MAKEUP_DB);
    let attack_coeff = (-1.0 / (ATTACK_MS * 0.001 * sample_rate)).exp();
    let release_coeff = (-1.0 / (RELEASE_MS * 0.001 * sample_rate)).exp();

    unsafe {
        let inp = std::slice::from_raw_parts(input, ch * frames);
        let out = std::slice::from_raw_parts_mut(output, ch * frames);
        let mut env = ENVELOPE;

        for i in 0..frames {
            // Peak detect across all channels
            let mut peak: f32 = 0.0;
            for c in 0..ch {
                let abs_val = inp[i * ch + c].abs();
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

            // Gain computation
            let gain = if env > threshold {
                let db_over = lin_to_db(env) - lin_to_db(threshold);
                let db_reduction = db_over * (1.0 - 1.0 / RATIO);
                db_to_lin(-db_reduction)
            } else {
                1.0
            };

            for c in 0..ch {
                let idx = i * ch + c;
                out[idx] = inp[idx] * gain * makeup;
            }
        }

        ENVELOPE = env;
    }
}
