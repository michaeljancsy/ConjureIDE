// Black Hole Vespers — gravitational drone with a slow choral chant stretched
// by time dilation.
//
// Sub-bass drone bus (rectify → 60 Hz LP) → very slow downward pitch sweep
// (dual-tap shifter) → 6 cascaded Schroeder allpass diffusers (longest reverb
// in the showcase) → swelling vowel formant cluster (3 peaking EQs at 500,
// 1100, 2200 Hz) → dark feedback comb tail → final mix.
//
// No distortion — this is the religious/contemplative cousin of Dying Star's
// catastrophic collapse.
//
// Params:
//   DILATION (pct) — pitch sweep depth/rate
//   CHANT    (pct) — vowel formant gain
//   DRONE    (pct) — sub bus level
//   SPACE    (pct) — comb reverb feedback (longest tail)
//   MIX            — wet/dry blend

use conjuredsp::*;
params! {
    DILATION = pct().default(55.0),
    CHANT = pct().default(60.0),
    DRONE = pct().default(70.0),
    SPACE = pct().default(75.0),
    MIX = mix().default(0.6),
}

const MAX_DL: usize = 70000;

const SHIFT_BASE_MS: f64 = 80.0;
const GRAIN_MS: f64 = 140.0;
const AP_MS: [f64; 6] = [7.3, 11.9, 17.3, 23.1, 31.7, 41.3];
const AP_G: f64 = 0.62;
const FORMANT_HZ: [f64; 3] = [500.0, 1100.0, 2200.0];
const TAIL_MS: f64 = 530.0;

static mut DRONE_LP: [Biquad; 2] = [Biquad::new(); 2];
static mut SHIFT_DL: [DelayLine<MAX_DL>; 2] = [DelayLine::new(); 2];
static mut AP: [[DelayLine<MAX_DL>; 6]; 2] = [[DelayLine::new(); 6]; 2];
static mut APS: [[f64; 6]; 2] = [[0.0; 6]; 2];
static mut FORMANT: [[Biquad; 3]; 2] = [[Biquad::new(); 3]; 2];
static mut TAIL_DL: [DelayLine<MAX_DL>; 2] = [DelayLine::new(); 2];
static mut TAIL_LP: [Biquad; 2] = [Biquad::new(); 2];
static mut TAIL_FB: [f64; 2] = [0.0; 2];
static mut GRAIN_PHASE: f64 = 0.0;

process! { ctx =>
    let sr = ctx.sample_rate() as f64;

    unsafe {
        let dilation = ctx.param(DILATION) as f64 / 100.0;
        let chant = ctx.param(CHANT) as f64 / 100.0;
        let drone = ctx.param(DRONE) as f64 / 100.0;
        let space = ctx.param(SPACE) as f64 / 100.0;
        let mx = ctx.param(MIX) as f64;

        let drone_lpc = BiquadCoeffs::lowpass(60.0, 0.707, sr);
        let formant_c: [BiquadCoeffs; 3] = [
            BiquadCoeffs::peak(FORMANT_HZ[0], 5.0, 8.0, sr),
            BiquadCoeffs::peak(FORMANT_HZ[1], 5.0, 8.0, sr),
            BiquadCoeffs::peak(FORMANT_HZ[2], 5.0, 8.0, sr),
        ];
        let tail_lpc = BiquadCoeffs::lowpass(2200.0, 0.707, sr);
        let nch = ctx.channels().min(2);
        for ch in 0..nch {
            DRONE_LP[ch].set_coeffs(drone_lpc);
            for k in 0..3 {
                FORMANT[ch][k].set_coeffs(formant_c[k]);
            }
            TAIL_LP[ch].set_coeffs(tail_lpc);
        }

        let base_d = SHIFT_BASE_MS * 0.001 * sr;
        let grain_samples = GRAIN_MS * 0.001 * sr;
        let grain_rate = (0.15 + 0.55 * dilation) / grain_samples;

        let ap_d: [f64; 6] = [
            (AP_MS[0] * 0.001 * sr).max(1.0),
            (AP_MS[1] * 0.001 * sr).max(1.0),
            (AP_MS[2] * 0.001 * sr).max(1.0),
            (AP_MS[3] * 0.001 * sr).max(1.0),
            (AP_MS[4] * 0.001 * sr).max(1.0),
            (AP_MS[5] * 0.001 * sr).max(1.0),
        ];
        let tail_d = TAIL_MS * 0.001 * sr;
        let tail_fb_amt = 0.60 + 0.25 * space;

        let drone_gain = drone * 1.4;
        let chant_gain = 0.18 + 0.32 * chant;

        for f in 0..ctx.frames() {
            let ph0 = GRAIN_PHASE;
            let ph1 = (GRAIN_PHASE + 0.5) % 1.0;
            let w0_ = (core::f64::consts::PI * ph0).sin();
            let w0 = w0_ * w0_;
            let w1_ = (core::f64::consts::PI * ph1).sin();
            let w1 = w1_ * w1_;
            let read0 = base_d + ph0 * grain_samples;
            let read1 = base_d + ph1 * grain_samples;
            GRAIN_PHASE = (GRAIN_PHASE + grain_rate) % 1.0;

            for ch in 0..nch {
                let dry = ctx.input(ch, f) as f64;

                let drone_voice = DRONE_LP[ch].process_sample(dry.abs()) * drone_gain;

                SHIFT_DL[ch].write(dry as f32);
                let g0 = SHIFT_DL[ch].read(read0) as f64;
                let g1 = SHIFT_DL[ch].read(read1) as f64;
                let shifted = w0 * g0 + w1 * g1;

                let mut sig = shifted;
                for k in 0..6 {
                    let vd = APS[ch][k];
                    let vn = sig + AP_G * vd;
                    AP[ch][k].write(vn as f32);
                    APS[ch][k] = AP[ch][k].read(ap_d[k]) as f64;
                    sig = vd - AP_G * vn;
                }

                let mut voiced = sig;
                voiced = FORMANT[ch][0].process_sample(voiced);
                voiced = FORMANT[ch][1].process_sample(voiced);
                voiced = FORMANT[ch][2].process_sample(voiced);
                voiced = voiced * chant_gain;

                let f_in = TAIL_LP[ch].process_sample(TAIL_FB[ch]);
                TAIL_DL[ch].write((voiced + tail_fb_amt * f_in) as f32);
                TAIL_FB[ch] = TAIL_DL[ch].read(tail_d) as f64;

                let wet = drone_voice + voiced + TAIL_FB[ch] * 0.6;
                ctx.set_output(ch, f, (dry * (1.0 - mx) + wet * mx) as f32);
            }
        }
    }
}
