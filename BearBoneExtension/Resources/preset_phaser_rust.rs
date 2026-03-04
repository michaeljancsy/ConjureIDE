// Phaser — cascaded allpass filters with LFO-swept frequency.
//
// Passes the signal through a cascade of first-order allpass filters
// whose cutoff frequency is swept by an LFO. The allpass filters shift
// the phase of different frequencies by different amounts, and when
// mixed with the dry signal, creates notches that sweep up and down
// the spectrum. The number of stages determines how many notches appear.

const MAX_CH: usize = 2;
const MAX_FR: usize = 4096;
const STAGES: usize = 4;

static mut INPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut OUTPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut PARAMS_BUF: [f32; 8] = [0.0; 8];

const RATE_HZ: f32 = 0.4;
const MIN_FREQ: f32 = 200.0;
const MAX_FREQ: f32 = 2000.0;
const MIX: f32 = 0.5;

// Persistent state per channel per stage: [x_prev, y_prev]
static mut AP_X_PREV: [[f32; STAGES]; MAX_CH] = [[0.0; STAGES]; MAX_CH];
static mut AP_Y_PREV: [[f32; STAGES]; MAX_CH] = [[0.0; STAGES]; MAX_CH];
static mut LFO_PHASE: f32 = 0.0;

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
    let two_pi = 2.0 * core::f32::consts::PI;
    let lfo_inc = two_pi * RATE_HZ / sample_rate;

    unsafe {
        let inp = std::slice::from_raw_parts(input, ch * frames);
        let out = std::slice::from_raw_parts_mut(output, ch * frames);
        let mut phase = LFO_PHASE;

        for i in 0..frames {
            // LFO sweeps the allpass frequency between MIN_FREQ and MAX_FREQ
            let lfo = 0.5 * (1.0 + phase.sin());
            let freq = MIN_FREQ + (MAX_FREQ - MIN_FREQ) * lfo;

            // Compute allpass coefficient
            let tan_val = (core::f32::consts::PI * freq / sample_rate).tan();
            let a = (tan_val - 1.0) / (tan_val + 1.0);

            for c in 0..ch {
                let idx = i * ch + c;
                let x = inp[idx];

                // Pass through allpass cascade
                let mut signal = x;
                for s in 0..STAGES {
                    let x_prev = AP_X_PREV[c][s];
                    let y_prev = AP_Y_PREV[c][s];
                    let y = a * signal + x_prev - a * y_prev;
                    AP_X_PREV[c][s] = signal;
                    AP_Y_PREV[c][s] = y;
                    signal = y;
                }

                // Mix dry + wet
                out[idx] = x * (1.0 - MIX) + signal * MIX;
            }

            phase += lfo_inc;
        }

        LFO_PHASE = phase % two_pi;
    }
}
