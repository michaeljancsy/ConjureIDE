// Auto-Wah — envelope-controlled bandpass filter.
//
// An envelope follower tracks the input level and sweeps a resonant
// bandpass filter across a frequency range. Louder playing pushes the
// filter higher; quiet passages bring it back down. The result is the
// classic funk/synth wah effect driven by playing dynamics.
//
// Params:
//   0 (Sensitivity): Input gain for envelope detection — -40 to 0 dB
//   1 (Depth):       Frequency sweep range — 0 to 100%
//   2 (Min Freq):    Lowest filter frequency — 200 to 800 Hz (log)
//   3 (Max Freq):    Highest filter frequency — 1000 to 8000 Hz (log)
//   4 (Q):           Filter resonance — 0.5 to 10
//   5 (Attack):      Envelope attack time — 0.5 to 50 ms (log)
//   6 (Release):     Envelope release time — 10 to 500 ms (log)

const MAX_CH: usize = 2;
const MAX_FR: usize = 4096;

static mut INPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut OUTPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut PARAMS_BUF: [f32; 16] = [0.0; 16];

// Parameter indices
const SENSITIVITY: usize = 0;
const DEPTH: usize = 1;
const MIN_FREQ: usize = 2;
const MAX_FREQ: usize = 3;
const Q_PARAM: usize = 4;
const ATTACK: usize = 5;
const RELEASE: usize = 6;

// Biquad state (Direct Form II Transposed)
static mut Z1: [f64; MAX_CH] = [0.0; MAX_CH];
static mut Z2: [f64; MAX_CH] = [0.0; MAX_CH];

// Envelope follower
static mut ENVELOPE: f64 = 0.0;

static METADATA: &str = r#"[{"name":"Sensitivity","min":-40.0,"max":0.0,"unit":"dB","default":-20.0},{"name":"Depth","min":0.0,"max":100.0,"unit":"%","default":80.0},{"name":"Min Freq","min":200.0,"max":800.0,"unit":"Hz","default":400.0,"curve":"log"},{"name":"Max Freq","min":1000.0,"max":8000.0,"unit":"Hz","default":3000.0,"curve":"log"},{"name":"Q","min":0.5,"max":10.0,"unit":"","default":3.0},{"name":"Attack","min":0.5,"max":50.0,"unit":"ms","default":5.0,"curve":"log"},{"name":"Release","min":10.0,"max":500.0,"unit":"ms","default":50.0,"curve":"log"}]"#;

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

fn smooth_coeff(time_ms: f64, sr: f64) -> f64 {
    if time_ms <= 0.0 {
        return 0.0;
    }
    (-1.0 / (time_ms * 0.001 * sr)).exp()
}

// Audio EQ Cookbook bandpass (constant skirt gain)
struct Coeffs {
    b0: f64,
    b1: f64,
    b2: f64,
    a1: f64,
    a2: f64,
}

fn bandpass(freq: f64, q: f64, sr: f64) -> Coeffs {
    let w0 = 2.0 * core::f64::consts::PI * freq / sr;
    let cos_w0 = w0.cos();
    let alpha = w0.sin() / (2.0 * q);
    let a0 = 1.0 + alpha;
    Coeffs {
        b0: alpha / a0,
        b1: 0.0,
        b2: -alpha / a0,
        a1: -2.0 * cos_w0 / a0,
        a2: (1.0 - alpha) / a0,
    }
}

#[inline]
fn biquad_sample(x: f64, c: &Coeffs, z1: &mut f64, z2: &mut f64) -> f64 {
    let y = c.b0 * x + *z1;
    *z1 = c.b1 * x - c.a1 * y + *z2;
    *z2 = c.b2 * x - c.a2 * y;
    y
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
        let sensitivity_gain = db_to_lin(PARAMS_BUF[SENSITIVITY] as f64);
        let depth = PARAMS_BUF[DEPTH] as f64 / 100.0;
        let min_freq = PARAMS_BUF[MIN_FREQ] as f64;
        let max_freq = PARAMS_BUF[MAX_FREQ] as f64;
        let q = PARAMS_BUF[Q_PARAM] as f64;
        let attack_ms = PARAMS_BUF[ATTACK] as f64;
        let release_ms = PARAMS_BUF[RELEASE] as f64;

        let attack_coeff = smooth_coeff(attack_ms, sr);
        let release_coeff = smooth_coeff(release_ms, sr);

        let freq_range = max_freq - min_freq;

        let inp = std::slice::from_raw_parts(input, ch * frames);
        let out = std::slice::from_raw_parts_mut(output, ch * frames);

        let mut env = ENVELOPE;

        for i in 0..frames {
            // Peak detect across channels with sensitivity scaling
            let mut peak_val: f64 = 0.0;
            for c in 0..ch {
                let idx = c * frames + i;
                let abs_val = (inp[idx] as f64).abs() * sensitivity_gain;
                if abs_val > peak_val {
                    peak_val = abs_val;
                }
            }

            // Envelope follower
            if peak_val > env {
                env = attack_coeff * env + (1.0 - attack_coeff) * peak_val;
            } else {
                env = release_coeff * env + (1.0 - release_coeff) * peak_val;
            }

            // Map envelope to filter frequency
            let mut env_clamped = env;
            if env_clamped < 0.0 {
                env_clamped = 0.0;
            }
            if env_clamped > 1.0 {
                env_clamped = 1.0;
            }
            let wah_freq = min_freq + depth * freq_range * env_clamped;

            // Compute bandpass coefficients per sample
            let bp = bandpass(wah_freq, q, sr);

            for c in 0..ch {
                let idx = c * frames + i;
                let x = inp[idx] as f64;
                out[idx] = biquad_sample(x, &bp, &mut Z1[c], &mut Z2[c]) as f32;
            }
        }

        ENVELOPE = env;
    }
}
