// 3-Band EQ — non-parametric equalizer with low shelf, mid peak, and high shelf.
//
// Fixed crossover frequencies at 200 Hz, 1 kHz, and 5 kHz. Each band has
// a gain control (+/-12 dB) and a bypass toggle. Three biquad filters in
// series shape the tone without requiring frequency knob adjustments.
//
// Params:
//   0 (Low Gain):    Low shelf gain — -12 to +12 dB
//   1 (Mid Gain):    Mid peak gain — -12 to +12 dB
//   2 (High Gain):   High shelf gain — -12 to +12 dB
//   3 (Low Bypass):  Bypass low band — 0 = active, 1 = bypass
//   4 (Mid Bypass):  Bypass mid band — 0 = active, 1 = bypass
//   5 (High Bypass): Bypass high band — 0 = active, 1 = bypass

const MAX_CH: usize = 2;
const MAX_FR: usize = 4096;

static mut INPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut OUTPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut PARAMS_BUF: [f32; 16] = [0.0; 16];

// Parameter indices
const LOW_GAIN: usize = 0;
const MID_GAIN: usize = 1;
const HIGH_GAIN: usize = 2;
const LOW_BYPASS: usize = 3;
const MID_BYPASS: usize = 4;
const HIGH_BYPASS: usize = 5;

// Fixed crossover points
const LOW_FREQ: f64 = 200.0;
const MID_FREQ: f64 = 1000.0;
const HIGH_FREQ: f64 = 5000.0;
const Q: f64 = 0.707;

// Biquad state per channel (Direct Form II Transposed)
// Low shelf
static mut Z1_LOW: [f64; MAX_CH] = [0.0; MAX_CH];
static mut Z2_LOW: [f64; MAX_CH] = [0.0; MAX_CH];
// Mid peak
static mut Z1_MID: [f64; MAX_CH] = [0.0; MAX_CH];
static mut Z2_MID: [f64; MAX_CH] = [0.0; MAX_CH];
// High shelf
static mut Z1_HIGH: [f64; MAX_CH] = [0.0; MAX_CH];
static mut Z2_HIGH: [f64; MAX_CH] = [0.0; MAX_CH];

static METADATA: &str = r#"[{"name":"Low Gain","min":-12.0,"max":12.0,"unit":"dB","default":0.0},{"name":"Mid Gain","min":-12.0,"max":12.0,"unit":"dB","default":0.0},{"name":"High Gain","min":-12.0,"max":12.0,"unit":"dB","default":0.0},{"name":"Low Bypass","min":0.0,"max":1.0,"unit":"","default":0.0},{"name":"Mid Bypass","min":0.0,"max":1.0,"unit":"","default":0.0},{"name":"High Bypass","min":0.0,"max":1.0,"unit":"","default":0.0}]"#;

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

// Biquad coefficients
struct Coeffs {
    b0: f64,
    b1: f64,
    b2: f64,
    a1: f64,
    a2: f64,
}

fn lowshelf(freq: f64, q: f64, gain_db: f64, sr: f64) -> Coeffs {
    let w0 = 2.0 * core::f64::consts::PI * freq / sr;
    let cos_w0 = w0.cos();
    let sin_w0 = w0.sin();
    let a_amp = (10.0_f64).powf(gain_db / 40.0);
    let alpha = sin_w0 / (2.0 * q);
    let two_sqrt_a_alpha = 2.0 * a_amp.sqrt() * alpha;
    let a0 = (a_amp + 1.0) + (a_amp - 1.0) * cos_w0 + two_sqrt_a_alpha;
    Coeffs {
        b0: (a_amp * ((a_amp + 1.0) - (a_amp - 1.0) * cos_w0 + two_sqrt_a_alpha)) / a0,
        b1: (2.0 * a_amp * ((a_amp - 1.0) - (a_amp + 1.0) * cos_w0)) / a0,
        b2: (a_amp * ((a_amp + 1.0) - (a_amp - 1.0) * cos_w0 - two_sqrt_a_alpha)) / a0,
        a1: (-2.0 * ((a_amp - 1.0) + (a_amp + 1.0) * cos_w0)) / a0,
        a2: ((a_amp + 1.0) + (a_amp - 1.0) * cos_w0 - two_sqrt_a_alpha) / a0,
    }
}

fn peak(freq: f64, q: f64, gain_db: f64, sr: f64) -> Coeffs {
    let w0 = 2.0 * core::f64::consts::PI * freq / sr;
    let cos_w0 = w0.cos();
    let a_amp = (10.0_f64).powf(gain_db / 40.0);
    let alpha = w0.sin() / (2.0 * q);
    let a0 = 1.0 + alpha / a_amp;
    Coeffs {
        b0: (1.0 + alpha * a_amp) / a0,
        b1: -2.0 * cos_w0 / a0,
        b2: (1.0 - alpha * a_amp) / a0,
        a1: -2.0 * cos_w0 / a0,
        a2: (1.0 - alpha / a_amp) / a0,
    }
}

fn highshelf(freq: f64, q: f64, gain_db: f64, sr: f64) -> Coeffs {
    let w0 = 2.0 * core::f64::consts::PI * freq / sr;
    let cos_w0 = w0.cos();
    let sin_w0 = w0.sin();
    let a_amp = (10.0_f64).powf(gain_db / 40.0);
    let alpha = sin_w0 / (2.0 * q);
    let two_sqrt_a_alpha = 2.0 * a_amp.sqrt() * alpha;
    let a0 = (a_amp + 1.0) - (a_amp - 1.0) * cos_w0 + two_sqrt_a_alpha;
    Coeffs {
        b0: (a_amp * ((a_amp + 1.0) + (a_amp - 1.0) * cos_w0 + two_sqrt_a_alpha)) / a0,
        b1: (-2.0 * a_amp * ((a_amp - 1.0) + (a_amp + 1.0) * cos_w0)) / a0,
        b2: (a_amp * ((a_amp + 1.0) + (a_amp - 1.0) * cos_w0 - two_sqrt_a_alpha)) / a0,
        a1: (2.0 * ((a_amp - 1.0) - (a_amp + 1.0) * cos_w0)) / a0,
        a2: ((a_amp + 1.0) - (a_amp - 1.0) * cos_w0 - two_sqrt_a_alpha) / a0,
    }
}

// Process one sample through a biquad (Direct Form II Transposed)
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
        let low_gain_db = PARAMS_BUF[LOW_GAIN] as f64;
        let mid_gain_db = PARAMS_BUF[MID_GAIN] as f64;
        let high_gain_db = PARAMS_BUF[HIGH_GAIN] as f64;
        let low_bypass = PARAMS_BUF[LOW_BYPASS] > 0.5;
        let mid_bypass = PARAMS_BUF[MID_BYPASS] > 0.5;
        let high_bypass = PARAMS_BUF[HIGH_BYPASS] > 0.5;

        let low_c = lowshelf(LOW_FREQ, Q, low_gain_db, sr);
        let mid_c = peak(MID_FREQ, Q, mid_gain_db, sr);
        let high_c = highshelf(HIGH_FREQ, Q, high_gain_db, sr);

        let inp = std::slice::from_raw_parts(input, ch * frames);
        let out = std::slice::from_raw_parts_mut(output, ch * frames);

        for c in 0..ch {
            for i in 0..frames {
                let idx = c * frames + i;
                let mut x = inp[idx] as f64;

                if !low_bypass {
                    x = biquad_sample(x, &low_c, &mut Z1_LOW[c], &mut Z2_LOW[c]);
                } else {
                    biquad_sample(x, &low_c, &mut Z1_LOW[c], &mut Z2_LOW[c]);
                }

                if !mid_bypass {
                    x = biquad_sample(x, &mid_c, &mut Z1_MID[c], &mut Z2_MID[c]);
                } else {
                    biquad_sample(x, &mid_c, &mut Z1_MID[c], &mut Z2_MID[c]);
                }

                if !high_bypass {
                    x = biquad_sample(x, &high_c, &mut Z1_HIGH[c], &mut Z2_HIGH[c]);
                } else {
                    biquad_sample(x, &high_c, &mut Z1_HIGH[c], &mut Z2_HIGH[c]);
                }

                out[idx] = x as f32;
            }
        }
    }
}
