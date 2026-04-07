// Cabinet Sim — speaker cabinet simulation.
//
// Models the frequency response of common guitar and bass cabinets
// using a chain of EQ filters. Real speakers have a sharp rolloff
// above 5-6 kHz, a resonant peak around 2-4 kHz, and limited bass
// response. The mic control simulates positioning from center cone
// (bright, harsh) to edge/off-axis (dark, smooth). Pair with
// amp_sim for a complete recording chain.
//
// Params:
//   cabinet:   Cabinet type (1x12, 2x12, 4x12, Bass 4x10)
//   mic:       Mic position (0 = center/bright, 1 = edge/dark)
//   resonance: Speaker cone resonance amount (0-1)

use conjuredsp::*;
setup!();

params! {
    CABINET = choice(&["1x12", "2x12", "4x12", "Bass 4x10"]).default(2.0),
    MIC = param(0.0, 1.0).default(0.5),
    RESONANCE = param(0.0, 1.0).default(0.4),
}

static mut LP1: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];
static mut LP2: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];
static mut HP: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];
static mut PEAK: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];
static mut NOTCH: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];

#[no_mangle]
pub extern "C" fn process(
    input: *const f32,
    output: *mut f32,
    channels: i32,
    frame_count: i32,
    sample_rate: f32,
) {
    let ctx = ctx(input, output, channels, frame_count, sample_rate);
    let sr = sample_rate as f64;

    unsafe {
        let cab_type = ctx.param(CABINET) as i32;
        let mic = ctx.param(MIC) as f64;
        let resonance = ctx.param(RESONANCE) as f64;

        // Cabinet characteristics
        let lp_freq: f64;
        let hp_freq: f64;
        let peak_freq: f64;
        let peak_gain: f64;

        if cab_type == 0 {
            // 1x12 — open back, bright
            lp_freq = 5500.0;
            hp_freq = 100.0;
            peak_freq = 3000.0;
            peak_gain = 3.0 + resonance * 4.0;
        } else if cab_type == 1 {
            // 2x12 — balanced
            lp_freq = 5000.0;
            hp_freq = 80.0;
            peak_freq = 2500.0;
            peak_gain = 4.0 + resonance * 4.0;
        } else if cab_type == 2 {
            // 4x12 — closed back, thick
            lp_freq = 4500.0;
            hp_freq = 70.0;
            peak_freq = 2000.0;
            peak_gain = 5.0 + resonance * 4.0;
        } else {
            // Bass 4x10
            lp_freq = 4000.0;
            hp_freq = 40.0;
            peak_freq = 800.0;
            peak_gain = 3.0 + resonance * 4.0;
        }

        // Mic position affects upper rolloff
        let lp_freq = lp_freq - mic * 2000.0;

        let lp1_coeffs = BiquadCoeffs::lowpass(lp_freq, 0.8, sr);
        let lp2_coeffs = BiquadCoeffs::lowpass(lp_freq * 1.5, 0.7, sr);
        let hp_coeffs = BiquadCoeffs::highpass(hp_freq, 0.7, sr);
        let peak_coeffs = BiquadCoeffs::peak(peak_freq, 1.5, peak_gain, sr);
        let notch_coeffs = BiquadCoeffs::notch(4500.0, 2.0, sr);

        for ch in 0..ctx.channels() {
            LP1[ch].set_coeffs(lp1_coeffs);
            LP2[ch].set_coeffs(lp2_coeffs);
            HP[ch].set_coeffs(hp_coeffs);
            PEAK[ch].set_coeffs(peak_coeffs);
            NOTCH[ch].set_coeffs(notch_coeffs);

            for i in 0..ctx.frames() {
                let mut x = ctx.input(ch, i) as f64;
                x = HP[ch].process_sample(x);
                x = LP1[ch].process_sample(x);
                x = LP2[ch].process_sample(x);
                x = PEAK[ch].process_sample(x);
                x = NOTCH[ch].process_sample(x);
                ctx.set_output(ch, i, x as f32);
            }
        }
    }
}
