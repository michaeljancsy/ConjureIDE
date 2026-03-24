// Phaser — cascaded allpass filters with LFO-swept frequency.
//
// Passes the signal through a cascade of first-order allpass filters
// whose cutoff frequency is swept by an LFO. The allpass filters shift
// the phase of different frequencies by different amounts, and when
// mixed with the dry signal, creates notches that sweep up and down
// the spectrum. The number of stages determines how many notches appear.
//
// Params:
//   0 (Rate):     LFO rate — 0.1 to 5.0 Hz
//   1 (Min Freq): Minimum sweep frequency — 50 to 500 Hz
//   2 (Max Freq): Maximum sweep frequency — 500 to 10000 Hz
//   3 (Stages):   Number of allpass stages — 2 to 6 (integer)
//   4 (Mix):      Dry/wet mix — 0.0 to 1.0

const MAX_CH: usize = 2;
const MAX_FR: usize = 4096;
const MAX_STAGES: usize = 6;

static mut INPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut OUTPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut PARAMS_BUF: [f32; 16] = [0.0; 16];

// Parameter indices
const RATE: usize = 0;     // 0.1–5.0 Hz
const MIN_FREQ: usize = 1; // 50–500 Hz
const MAX_FREQ: usize = 2; // 500–10000 Hz
const STAGES: usize = 3;   // 2–6 (integer)
const MIX: usize = 4;      // 0.0–1.0

// Persistent state per channel per stage: [x_prev, y_prev]
// Use f64 to match Python's float64 precision in the allpass feedback.
static mut AP_X_PREV: [[f64; MAX_STAGES]; MAX_CH] = [[0.0; MAX_STAGES]; MAX_CH];
static mut AP_Y_PREV: [[f64; MAX_STAGES]; MAX_CH] = [[0.0; MAX_STAGES]; MAX_CH];
static mut LFO_PHASE: f64 = 0.0;

static METADATA: &str = r#"[{"name":"Rate","min":0.1,"max":5.0,"unit":"Hz","default":1.0},{"name":"Min Freq","min":50.0,"max":500.0,"unit":"Hz","default":200.0},{"name":"Max Freq","min":500.0,"max":10000.0,"unit":"Hz","default":5000.0},{"name":"Stages","min":2.0,"max":6.0,"unit":"","default":4.0},{"name":"Mix","min":0.0,"max":1.0,"unit":"","default":0.5}]"#;

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
    let two_pi = 2.0 * core::f64::consts::PI;

    unsafe {
        let rate_hz = PARAMS_BUF[RATE] as f64;
        let min_freq = PARAMS_BUF[MIN_FREQ] as f64;
        let max_freq = PARAMS_BUF[MAX_FREQ] as f64;
        let stages = (PARAMS_BUF[STAGES] as f64).round() as usize;
        let mix = PARAMS_BUF[MIX] as f64;

        let lfo_inc = two_pi * rate_hz / sr;
        let inp = std::slice::from_raw_parts(input, ch * frames);
        let out = std::slice::from_raw_parts_mut(output, ch * frames);
        let mut phase = LFO_PHASE;

        let num_stages = if stages > MAX_STAGES { MAX_STAGES } else { stages };

        for i in 0..frames {
            // LFO sweeps the allpass frequency between min_freq and max_freq
            let lfo = 0.5 * (1.0 + phase.sin());
            let freq = min_freq + (max_freq - min_freq) * lfo;

            // Compute allpass coefficient
            let tan_val = (core::f64::consts::PI * freq / sr).tan();
            let a = (tan_val - 1.0) / (tan_val + 1.0);

            for c in 0..ch {
                let idx = c * frames + i;
                let x = inp[idx] as f64;

                // Pass through allpass cascade
                let mut signal = x;
                for s in 0..num_stages {
                    let x_prev = AP_X_PREV[c][s];
                    let y_prev = AP_Y_PREV[c][s];
                    let y = a * signal + x_prev - a * y_prev;
                    AP_X_PREV[c][s] = signal;
                    AP_Y_PREV[c][s] = y;
                    signal = y;
                }

                // Mix dry + wet
                out[idx] = (x * (1.0 - mix) + signal * mix) as f32;
            }

            phase += lfo_inc;
        }

        LFO_PHASE = phase % two_pi;
    }
}
