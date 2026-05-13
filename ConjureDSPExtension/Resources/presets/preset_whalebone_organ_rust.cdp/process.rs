// Whalebone Organ — a pipe organ carved from cetacean bone, sub harmonics
// resonating through the hull.
//
// Sub-octave generator (rectify → 70 Hz LP) → low/mid 8-partial modal bank
// (82.4 / 123.5 / 164.8 / 220 / 329.6 / 440 / 523.3 / 659.3 Hz high-Q
// bandpass — E-major chord voicings in the 80–660 Hz range) with slow
// per-partial amplitude LFOs ("breathing" 0.11–0.37 Hz) → 2 allpass
// diffusers → short comb tail → final mix.
//
// Distinct from Glass Smash: low-range modal bank (80–660 Hz) vs Glass
// Smash's high inharmonic bank (2.7–11.2 kHz). Distinct from Astronaut's
// Garden: pipe-organ sustain via per-partial breathing envelopes instead of
// shared sub-Hz ring modulation.
//
// Params:
//   PIPES  (pct) — modal resonator Q (12 → 40)
//   BREATH (pct) — per-partial breathing LFO depth
//   SUB    (pct) — sub-octave level
//   AIR    (pct) — reverb feedback
//   MIX          — wet/dry blend

use conjuredsp::*;
params! {
    PIPES = pct().default(60.0),
    BREATH = pct().default(55.0),
    SUB = pct().default(55.0),
    AIR = pct().default(50.0),
    MIX = mix().default(0.55),
}

const MAX_DL: usize = 30000;

const PIPE_HZ: [f64; 8] = [82.4, 123.5, 164.8, 220.0, 329.6, 440.0, 523.3, 659.3];
const BREATH_HZ: [f64; 8] = [0.11, 0.13, 0.17, 0.19, 0.23, 0.29, 0.31, 0.37];
const AP_MS: [f64; 2] = [9.7, 13.1];
const AP_G: f64 = 0.55;
const COMB_MS: [f64; 2] = [97.0, 131.0];

persist_mut!(SUB_LP: [Biquad; 2] = [Biquad::new(); 2]);
persist_mut!(PIPES_F: [[Biquad; 8]; 2] = [[Biquad::new(); 8]; 2]);
persist_mut!(BREATH_LFO: [Lfo; 8] = [Lfo::new(); 8]);
persist_mut!(AP: [[DelayLine<MAX_DL>; 2]; 2] = [[DelayLine::new(); 2]; 2]);
persist_mut!(APS: [[f64; 2]; 2] = [[0.0; 2]; 2]);
persist_mut!(COMBS: [[DelayLine<MAX_DL>; 2]; 2] = [[DelayLine::new(); 2]; 2]);
persist_mut!(COMB_LP: [[Biquad; 2]; 2] = [[Biquad::new(); 2]; 2]);
persist_mut!(COMB_FB_BUF: [[f64; 2]; 2] = [[0.0; 2]; 2]);

process! { ctx =>
    let sr = ctx.sample_rate() as f64;

    let pipes = ctx.param(PIPES) as f64 / 100.0;
    let breath = ctx.param(BREATH) as f64 / 100.0;
    let sub = ctx.param(SUB) as f64 / 100.0;
    let air = ctx.param(AIR) as f64 / 100.0;
    let mx = ctx.param(MIX) as f64;

    let pipe_q = 12.0 + 28.0 * pipes;
    let mut pipe_c: [BiquadCoeffs; 8] = [BiquadCoeffs::identity(); 8];
    for k in 0..8 {
        pipe_c[k] = BiquadCoeffs::bandpass(PIPE_HZ[k], pipe_q, sr);
    }
    let sub_lpc = BiquadCoeffs::lowpass(70.0, 0.707, sr);
    let comb_lpc = BiquadCoeffs::lowpass(2200.0, 0.707, sr);

    let nch = ctx.channels().min(2);

    let ap_d: [f64; 2] = [
        (AP_MS[0] * 0.001 * sr).max(1.0),
        (AP_MS[1] * 0.001 * sr).max(1.0),
    ];
    let comb_d: [f64; 2] = [
        COMB_MS[0] * 0.001 * sr,
        COMB_MS[1] * 0.001 * sr,
    ];
    let comb_fb_amt = 0.50 + 0.35 * air;

    let sub_gain = 0.4 + 0.8 * sub;
    let pipe_base_gain: f64 = 1.0 / 8.0;
    let breath_depth = 0.50 * breath;

    SUB_LP.with_mut(|sub_lp| {
        PIPES_F.with_mut(|pipes_f| {
            BREATH_LFO.with_mut(|breath_lfo| {
                AP.with_mut(|ap| {
                    APS.with_mut(|aps| {
                        COMBS.with_mut(|combs| {
                            COMB_LP.with_mut(|comb_lp| {
                                COMB_FB_BUF.with_mut(|comb_fb_buf| {
                                    for k in 0..8 {
                                        breath_lfo[k].init(sr, BREATH_HZ[k]);
                                    }

                                    for ch in 0..nch {
                                        sub_lp[ch].set_coeffs(sub_lpc);
                                        for k in 0..8 {
                                            pipes_f[ch][k].set_coeffs(pipe_c[k]);
                                        }
                                        for k in 0..2 {
                                            comb_lp[ch][k].set_coeffs(comb_lpc);
                                        }
                                    }

                                    for f in 0..ctx.frames() {
                                        let bm: [f64; 8] = [
                                            breath_lfo[0].tick(),
                                            breath_lfo[1].tick(),
                                            breath_lfo[2].tick(),
                                            breath_lfo[3].tick(),
                                            breath_lfo[4].tick(),
                                            breath_lfo[5].tick(),
                                            breath_lfo[6].tick(),
                                            breath_lfo[7].tick(),
                                        ];

                                        for ch in 0..nch {
                                            let dry = ctx.input(ch, f) as f64;

                                            let sub_voice = sub_lp[ch].process_sample(dry.abs()) * sub_gain;

                                            let mut pipe_sum: f64 = 0.0;
                                            for k in 0..8 {
                                                let voice = pipes_f[ch][k].process_sample(dry);
                                                let gain = (1.0 - breath_depth) + breath_depth * (0.5 + 0.5 * bm[k]);
                                                pipe_sum += voice * gain;
                                            }
                                            pipe_sum *= pipe_base_gain;

                                            let mut sig = pipe_sum + sub_voice;
                                            for k in 0..2 {
                                                let vd = aps[ch][k];
                                                let vn = sig + AP_G * vd;
                                                ap[ch][k].write(vn as f32);
                                                aps[ch][k] = ap[ch][k].read(ap_d[k]) as f64;
                                                sig = vd - AP_G * vn;
                                            }

                                            let mut tail_sum: f64 = 0.0;
                                            for k in 0..2 {
                                                let f_in = comb_lp[ch][k].process_sample(comb_fb_buf[ch][k]);
                                                combs[ch][k].write((sig + comb_fb_amt * f_in) as f32);
                                                comb_fb_buf[ch][k] = combs[ch][k].read(comb_d[k]) as f64;
                                                tail_sum += comb_fb_buf[ch][k];
                                            }
                                            tail_sum *= 0.5;

                                            let wet = pipe_sum + sub_voice + sig * 0.3 + tail_sum;
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
}
