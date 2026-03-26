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

use conjuredsp::*;
setup!();

params! {
    LOW_GAIN = db().min(-12.0).max(12.0),
    MID_GAIN = db().min(-12.0).max(12.0),
    HIGH_GAIN = db().min(-12.0).max(12.0),
    LOW_BYPASS = toggle(),
    MID_BYPASS = toggle(),
    HIGH_BYPASS = toggle(),
}

// Fixed crossover points
const LOW_FREQ: f64 = 200.0;
const MID_FREQ: f64 = 1000.0;
const HIGH_FREQ: f64 = 5000.0;
const Q: f64 = 0.707;

// Biquad state per channel
static mut LOW: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];
static mut MID: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];
static mut HIGH: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];

#[no_mangle]
pub extern "C" fn process(
    input: *const f32,
    output: *mut f32,
    channels: i32,
    frame_count: i32,
    sample_rate: f32,
) {
    let ctx = ctx(input, output, channels, frame_count, sample_rate);
    let sr = ctx.sample_rate() as f64;

    unsafe {
        let low_gain_db = ctx.param(LOW_GAIN) as f64;
        let mid_gain_db = ctx.param(MID_GAIN) as f64;
        let high_gain_db = ctx.param(HIGH_GAIN) as f64;
        let low_bypass = ctx.param(LOW_BYPASS) > 0.5;
        let mid_bypass = ctx.param(MID_BYPASS) > 0.5;
        let high_bypass = ctx.param(HIGH_BYPASS) > 0.5;

        let low_c = BiquadCoeffs::lowshelf(LOW_FREQ, Q, low_gain_db, sr);
        let mid_c = BiquadCoeffs::peak(MID_FREQ, Q, mid_gain_db, sr);
        let high_c = BiquadCoeffs::highshelf(HIGH_FREQ, Q, high_gain_db, sr);

        for c in 0..ctx.channels() {
            LOW[c].set_coeffs(low_c);
            MID[c].set_coeffs(mid_c);
            HIGH[c].set_coeffs(high_c);

            for i in 0..ctx.frames() {
                let mut x = ctx.input(c, i) as f64;

                // Always process to keep filter state current
                let filtered = LOW[c].process_sample(x);
                if !low_bypass {
                    x = filtered;
                }

                let filtered = MID[c].process_sample(x);
                if !mid_bypass {
                    x = filtered;
                }

                let filtered = HIGH[c].process_sample(x);
                if !high_bypass {
                    x = filtered;
                }

                ctx.set_output(c, i, x as f32);
            }
        }
    }
}
