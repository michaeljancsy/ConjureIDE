// Termite Cathedral — vast stone hall full of insect chatter.
//
// 8-tap micro-grain cloud (short delay taps at 3–28 ms, each wavering via an
// independent coprime LFO) as the *primary* layer → 4-resonator chatter bank
// (high-Q bandpass at 800 / 1600 / 2700 / 4200 Hz) → 4 parallel cathedral
// combs (137 / 179 / 223 / 277 ms, LP in feedback) → final mix.
//
// Distinct from Glass Smash: here the granular cloud IS the sound, not a
// side stage. Distinct from Haunted Cathedral: narrower, chattier combs fed
// by a pre-diffused grain bed rather than raw input.
//
// Params:
//   DENSITY (pct) — cloud tap gain + LFO modulation depth
//   CLATTER (pct) — resonator Q (6 → 28)
//   HALL    (pct) — comb reverb feedback
//   SHEEN   (pct) — post-reverb highpass freq (brightness)
//   MIX           — wet/dry blend

use conjuredsp::*;
setup!();

params! {
    DENSITY = pct().default(65.0),
    CLATTER = pct().default(55.0),
    HALL = pct().default(70.0),
    SHEEN = pct().default(50.0),
    MIX = mix().default(0.6),
}

const MAX_DL: usize = 50000;

const TAP_MS: [f64; 8] = [3.1, 5.3, 7.9, 11.7, 14.3, 18.1, 22.9, 27.7];
const TAP_LFO_HZ: [f64; 8] = [0.7, 1.1, 1.4, 1.9, 2.3, 3.1, 4.1, 5.3];
const RES_HZ: [f64; 4] = [800.0, 1600.0, 2700.0, 4200.0];
const COMB_MS: [f64; 4] = [137.0, 179.0, 223.0, 277.0];

static mut GRAIN_DL: [DelayLine<MAX_DL>; 2] = [DelayLine::new(); 2];
static mut TAP_LFO: [Lfo; 8] = [Lfo::new(); 8];
static mut RES: [[Biquad; 4]; 2] = [[Biquad::new(); 4]; 2];
static mut COMBS: [[DelayLine<MAX_DL>; 4]; 2] = [[DelayLine::new(); 4]; 2];
static mut COMB_LP: [[Biquad; 4]; 2] = [[Biquad::new(); 4]; 2];
static mut COMB_FB_BUF: [[f64; 4]; 2] = [[0.0; 4]; 2];
static mut HP: [Biquad; 2] = [Biquad::new(); 2];

#[no_mangle]
pub extern "C" fn process(
    input: *const f32, output: *mut f32,
    channels: i32, frame_count: i32, sample_rate: f32,
) {
    let ctx = ctx(input, output, channels, frame_count, sample_rate);
    let sr = ctx.sample_rate() as f64;

    unsafe {
        let density = ctx.param(DENSITY) as f64 / 100.0;
        let clatter = ctx.param(CLATTER) as f64 / 100.0;
        let hall = ctx.param(HALL) as f64 / 100.0;
        let sheen = ctx.param(SHEEN) as f64 / 100.0;
        let mx = ctx.param(MIX) as f64;

        let res_q = 6.0 + 22.0 * clatter;
        let res_c: [BiquadCoeffs; 4] = [
            BiquadCoeffs::bandpass(RES_HZ[0], res_q, sr),
            BiquadCoeffs::bandpass(RES_HZ[1], res_q, sr),
            BiquadCoeffs::bandpass(RES_HZ[2], res_q, sr),
            BiquadCoeffs::bandpass(RES_HZ[3], res_q, sr),
        ];
        let comb_lpc = BiquadCoeffs::lowpass(3200.0, 0.707, sr);
        let hp_fc = 200.0 + 1800.0 * sheen;
        let hpc = BiquadCoeffs::highpass(hp_fc, 0.707, sr);

        for k in 0..8 {
            TAP_LFO[k].init(sr, TAP_LFO_HZ[k]);
        }

        let nch = ctx.channels().min(2);
        for ch in 0..nch {
            for k in 0..4 {
                RES[ch][k].set_coeffs(res_c[k]);
                COMB_LP[ch][k].set_coeffs(comb_lpc);
            }
            HP[ch].set_coeffs(hpc);
        }

        let tap_base: [f64; 8] = [
            TAP_MS[0] * 0.001 * sr,
            TAP_MS[1] * 0.001 * sr,
            TAP_MS[2] * 0.001 * sr,
            TAP_MS[3] * 0.001 * sr,
            TAP_MS[4] * 0.001 * sr,
            TAP_MS[5] * 0.001 * sr,
            TAP_MS[6] * 0.001 * sr,
            TAP_MS[7] * 0.001 * sr,
        ];
        let tap_depth = (0.5 + 1.5 * density) * 0.001 * sr;
        let comb_d: [f64; 4] = [
            COMB_MS[0] * 0.001 * sr,
            COMB_MS[1] * 0.001 * sr,
            COMB_MS[2] * 0.001 * sr,
            COMB_MS[3] * 0.001 * sr,
        ];
        let comb_fb_amt = 0.60 + 0.30 * hall;

        let tap_gain = (0.4 + 0.6 * density) / 8.0;

        for f in 0..ctx.frames() {
            let lm: [f64; 8] = [
                TAP_LFO[0].tick(),
                TAP_LFO[1].tick(),
                TAP_LFO[2].tick(),
                TAP_LFO[3].tick(),
                TAP_LFO[4].tick(),
                TAP_LFO[5].tick(),
                TAP_LFO[6].tick(),
                TAP_LFO[7].tick(),
            ];

            for ch in 0..nch {
                let dry = ctx.input(ch, f) as f64;

                GRAIN_DL[ch].write(dry as f32);

                let mut cloud: f64 = 0.0;
                for k in 0..8 {
                    let mut d = tap_base[k] + lm[k] * tap_depth;
                    if d < 1.0 {
                        d = 1.0;
                    }
                    cloud += GRAIN_DL[ch].read(d) as f64;
                }
                cloud *= tap_gain;

                let mut res_sum: f64 = 0.0;
                for k in 0..4 {
                    res_sum += RES[ch][k].process_sample(cloud);
                }
                res_sum *= 0.25;

                let comb_in = cloud + res_sum;
                let mut tail_sum: f64 = 0.0;
                for k in 0..4 {
                    let f_in = COMB_LP[ch][k].process_sample(COMB_FB_BUF[ch][k]);
                    COMBS[ch][k].write((comb_in + comb_fb_amt * f_in) as f32);
                    COMB_FB_BUF[ch][k] = COMBS[ch][k].read(comb_d[k]) as f64;
                    tail_sum += COMB_FB_BUF[ch][k];
                }
                tail_sum *= 0.25;

                let wet = HP[ch].process_sample(cloud + res_sum + tail_sum);

                ctx.set_output(ch, f, (dry * (1.0 - mx) + wet * mx) as f32);
            }
        }
    }
}
