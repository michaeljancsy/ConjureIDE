// Compressor — dynamic range compression with envelope follower.
//
// Reduces the dynamic range of the audio signal using a peak-detecting
// envelope follower. When the signal exceeds the threshold, gain is reduced
// according to the compression ratio. Attack and release times control how
// quickly the compressor responds to level changes. Makeup gain compensates
// for the overall volume reduction caused by compression.
//
// The envelope follower operates per-sample across all channels (peak detection),
// so stereo signals are compressed with linked gain to preserve the stereo image.
//
// Params:
//   0 (Threshold): Compression threshold — -40 to -3 dB
//   1 (Ratio):     Compression ratio — 2:1 to 20:1
//   2 (Attack):    Attack time — 0.5 to 50 ms
//   3 (Release):   Release time — 10 to 500 ms
//   4 (Makeup):    Makeup gain — 0 to 20 dB

const MAX_CH: usize = 2;
const MAX_FR: usize = 4096;

static mut INPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut OUTPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut PARAMS_BUF: [f32; 16] = [0.0; 16];

// Parameter indices
const THRESHOLD: usize = 0; // -40 to -3 dB
const RATIO: usize = 1;     // 2:1 to 20:1
const ATTACK: usize = 2;    // 0.5–50 ms
const RELEASE: usize = 3;   // 10–500 ms
const MAKEUP: usize = 4;    // 0–20 dB

// Persistent envelope follower state
// Use f64 to match Python's float64 precision in the envelope feedback loop.
static mut ENVELOPE: f64 = 0.0;

static METADATA: &str = r#"[{"name":"Threshold","min":-40.0,"max":-3.0,"unit":"dB","default":-20.0},{"name":"Ratio","min":2.0,"max":20.0,"unit":":1","default":4.0},{"name":"Attack","min":0.5,"max":50.0,"unit":"ms","default":5.0},{"name":"Release","min":10.0,"max":500.0,"unit":"ms","default":50.0},{"name":"Makeup","min":0.0,"max":20.0,"unit":"dB","default":0.0}]"#;

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

fn db_to_lin(db: f64) -> f64 {
    (10.0_f64).powf(db / 20.0)
}

fn lin_to_db(lin: f64) -> f64 {
    20.0 * (lin + 1e-30).log10()
}

/// Compressor — dynamic range compression with envelope follower.
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
        let ratio = PARAMS_BUF[RATIO] as f64;
        let attack_ms = PARAMS_BUF[ATTACK] as f64;
        let release_ms = PARAMS_BUF[RELEASE] as f64;
        let makeup_db = PARAMS_BUF[MAKEUP] as f64;

        let threshold = db_to_lin(threshold_db);
        let makeup = db_to_lin(makeup_db);
        let attack_coeff = (-1.0 / (attack_ms * 0.001 * sr)).exp();
        let release_coeff = (-1.0 / (release_ms * 0.001 * sr)).exp();
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

            // Gain computation
            let gain = if env > threshold {
                let db_over = lin_to_db(env) - lin_to_db(threshold);
                let db_reduction = db_over * (1.0 - 1.0 / ratio);
                db_to_lin(-db_reduction)
            } else {
                1.0
            };

            for c in 0..ch {
                let idx = c * frames + i;
                out[idx] = (inp[idx] as f64 * gain * makeup) as f32;
            }
        }

        ENVELOPE = env;
    }
}
