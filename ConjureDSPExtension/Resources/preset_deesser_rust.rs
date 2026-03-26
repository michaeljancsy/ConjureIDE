// De-esser — sibilance reduction via sidechain compression.
//
// A bandpass filter isolates sibilant frequencies from the input signal.
// An envelope follower tracks the level of the isolated band. When it
// exceeds the threshold, gain reduction is applied to the full-band
// original signal, taming harshness without affecting the overall tone.
//
// Params:
//   0 (Frequency): Sibilance center frequency — 2000 to 12000 Hz (log)
//   1 (Q):         Sidechain bandpass Q — 0.5 to 5
//   2 (Threshold): Detection threshold — -40 to 0 dB
//   3 (Reduction): Maximum gain reduction — -20 to 0 dB
//   4 (Attack):    Envelope attack time — 0.1 to 10 ms (log)
//   5 (Release):   Envelope release time — 10 to 200 ms (log)

const MAX_CH: usize = 2;
const MAX_FR: usize = 4096;

static mut INPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut OUTPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut PARAMS_BUF: [f32; 16] = [0.0; 16];

// Parameter indices
const FREQUENCY: usize = 0;
const Q_PARAM: usize = 1;
const THRESHOLD: usize = 2;
const REDUCTION: usize = 3;
const ATTACK: usize = 4;
const RELEASE: usize = 5;

// Sidechain biquad state (Direct Form II Transposed)
static mut SC_Z1: [f64; MAX_CH] = [0.0; MAX_CH];
static mut SC_Z2: [f64; MAX_CH] = [0.0; MAX_CH];

// Envelope follower
static mut ENVELOPE: f64 = 0.0;

static METADATA: &str = r#"[{"name":"Frequency","min":2000.0,"max":12000.0,"unit":"Hz","default":6000.0,"curve":"log"},{"name":"Q","min":0.5,"max":5.0,"unit":"","default":1.5},{"name":"Threshold","min":-40.0,"max":0.0,"unit":"dB","default":-20.0},{"name":"Reduction","min":-20.0,"max":0.0,"unit":"dB","default":-6.0},{"name":"Attack","min":0.1,"max":10.0,"unit":"ms","default":1.0,"curve":"log"},{"name":"Release","min":10.0,"max":200.0,"unit":"ms","default":50.0,"curve":"log"}]"#;

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
        let center_freq = PARAMS_BUF[FREQUENCY] as f64;
        let q = PARAMS_BUF[Q_PARAM] as f64;
        let threshold_db = PARAMS_BUF[THRESHOLD] as f64;
        let reduction_db = PARAMS_BUF[REDUCTION] as f64;
        let attack_ms = PARAMS_BUF[ATTACK] as f64;
        let release_ms = PARAMS_BUF[RELEASE] as f64;

        let threshold_lin = db_to_lin(threshold_db);
        let attack_coeff = smooth_coeff(attack_ms, sr);
        let release_coeff = smooth_coeff(release_ms, sr);

        let bp = bandpass(center_freq, q, sr);

        let inp = std::slice::from_raw_parts(input, ch * frames);
        let out = std::slice::from_raw_parts_mut(output, ch * frames);

        let mut env = ENVELOPE;

        for i in 0..frames {
            // Sidechain: bandpass filter then peak detect across channels
            let mut sc_peak: f64 = 0.0;
            for c in 0..ch {
                let idx = c * frames + i;
                let x = inp[idx] as f64;
                let sc = biquad_sample(x, &bp, &mut SC_Z1[c], &mut SC_Z2[c]);
                let abs_sc = sc.abs();
                if abs_sc > sc_peak {
                    sc_peak = abs_sc;
                }
            }

            // Envelope follower
            if sc_peak > env {
                env = attack_coeff * env + (1.0 - attack_coeff) * sc_peak;
            } else {
                env = release_coeff * env + (1.0 - release_coeff) * sc_peak;
            }

            // Gain computation
            let gain = if env > threshold_lin {
                let over_db = lin_to_db(env) - lin_to_db(threshold_lin);
                let mut over_ratio = over_db / 6.0;
                if over_ratio > 1.0 {
                    over_ratio = 1.0;
                }
                if over_ratio < 0.0 {
                    over_ratio = 0.0;
                }
                db_to_lin(reduction_db * over_ratio)
            } else {
                1.0
            };

            for c in 0..ch {
                let idx = c * frames + i;
                out[idx] = (inp[idx] as f64 * gain) as f32;
            }
        }

        ENVELOPE = env;
    }
}
