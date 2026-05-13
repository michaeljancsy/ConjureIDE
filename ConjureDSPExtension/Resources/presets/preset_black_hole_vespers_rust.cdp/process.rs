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

persist_mut!(DRONE_LP: [Biquad; 2] = [Biquad::new(); 2]);
persist_mut!(SHIFT_DL: [DelayLine<MAX_DL>; 2] = [DelayLine::new(); 2]);
persist_mut!(AP: [[DelayLine<MAX_DL>; 6]; 2] = [[DelayLine::new(); 6]; 2]);
persist_mut!(APS: [[f64; 6]; 2] = [[0.0; 6]; 2]);
persist_mut!(FORMANT: [[Biquad; 3]; 2] = [[Biquad::new(); 3]; 2]);
persist_mut!(TAIL_DL: [DelayLine<MAX_DL>; 2] = [DelayLine::new(); 2]);
persist_mut!(TAIL_LP: [Biquad; 2] = [Biquad::new(); 2]);
persist_mut!(TAIL_FB: [f64; 2] = [0.0; 2]);
persist!(GRAIN_PHASE: f64 = 0.0);

process! { ctx =>
    let sr = ctx.sample_rate() as f64;

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

    let mut grain_phase = GRAIN_PHASE.get();

    DRONE_LP.with_mut(|drone_lp| {
        SHIFT_DL.with_mut(|shift_dl| {
            AP.with_mut(|ap| {
                APS.with_mut(|aps| {
                    FORMANT.with_mut(|formant| {
                        TAIL_DL.with_mut(|tail_dl| {
                            TAIL_LP.with_mut(|tail_lp| {
                                TAIL_FB.with_mut(|tail_fb| {
                                    for ch in 0..nch {
                                        drone_lp[ch].set_coeffs(drone_lpc);
                                        for k in 0..3 {
                                            formant[ch][k].set_coeffs(formant_c[k]);
                                        }
                                        tail_lp[ch].set_coeffs(tail_lpc);
                                    }

                                    for f in 0..ctx.frames() {
                                        let ph0 = grain_phase;
                                        let ph1 = (grain_phase + 0.5) % 1.0;
                                        let w0_ = (core::f64::consts::PI * ph0).sin();
                                        let w0 = w0_ * w0_;
                                        let w1_ = (core::f64::consts::PI * ph1).sin();
                                        let w1 = w1_ * w1_;
                                        let read0 = base_d + ph0 * grain_samples;
                                        let read1 = base_d + ph1 * grain_samples;
                                        grain_phase = (grain_phase + grain_rate) % 1.0;

                                        for ch in 0..nch {
                                            let dry = ctx.input(ch, f) as f64;

                                            let drone_voice = drone_lp[ch].process_sample(dry.abs()) * drone_gain;

                                            shift_dl[ch].write(dry as f32);
                                            let g0 = shift_dl[ch].read(read0) as f64;
                                            let g1 = shift_dl[ch].read(read1) as f64;
                                            let shifted = w0 * g0 + w1 * g1;

                                            let mut sig = shifted;
                                            for k in 0..6 {
                                                let vd = aps[ch][k];
                                                let vn = sig + AP_G * vd;
                                                ap[ch][k].write(vn as f32);
                                                aps[ch][k] = ap[ch][k].read(ap_d[k]) as f64;
                                                sig = vd - AP_G * vn;
                                            }

                                            let mut voiced = sig;
                                            voiced = formant[ch][0].process_sample(voiced);
                                            voiced = formant[ch][1].process_sample(voiced);
                                            voiced = formant[ch][2].process_sample(voiced);
                                            voiced = voiced * chant_gain;

                                            let f_in = tail_lp[ch].process_sample(tail_fb[ch]);
                                            tail_dl[ch].write((voiced + tail_fb_amt * f_in) as f32);
                                            tail_fb[ch] = tail_dl[ch].read(tail_d) as f64;

                                            let wet = drone_voice + voiced + tail_fb[ch] * 0.6;
                                            ctx.set_output(ch, f, (dry * (1.0 - mx) + wet * mx) as f32);
                                        }
                                    }
                                });
                            });
                        });
                    });
                });
            });
        });
    });

    GRAIN_PHASE.set(grain_phase);
}
