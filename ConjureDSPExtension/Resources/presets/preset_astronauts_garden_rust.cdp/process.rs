// Astronaut's Garden — bell-like organic blooms drifting in a vacuum.
//
// Just-intonation harmonic resonator bank (8 partials at 1, 2, 3, 5, 6, 7, 9,
// 11 × 220 Hz fundamental, high-Q bandpass) → sub-Hz ring modulation (very
// slow LFO carriers, 0.13 / 0.21 Hz) → 4-voice prime-spaced chorus → spacious
// lowpass-feedback comb reverb → final mix.
//
// Distinct from Glass Smash: this bank is *harmonic* (just-intonation) rather
// than inharmonic glass spectra, producing bell-like consonant blooms instead
// of metallic crash. Sub-Hz ring-mod carriers swell rather than buzz.
//
// Controls:
//   BLOOM  (pct) — resonator Q (10 → 30)
//   DRIFT  (pct) — sub-Hz ring-mod depth
//   CHORUS (pct) — chorus depth
//   GARDEN (pct) — reverb feedback
//   MIX          — wet/dry blend

use conjuredsp::*;
params! {
    BLOOM = pct().default(55.0),
    DRIFT = pct().default(60.0),
    CHORUS = pct().default(50.0),
    GARDEN = pct().default(65.0),
    MIX = mix().default(0.55),
}

const MAX_DL: usize = 40000;

const FUNDAMENTAL: f64 = 220.0;
const HARMONICS: [f64; 8] = [1.0, 2.0, 3.0, 5.0, 6.0, 7.0, 9.0, 11.0];
const RING_HZ: [f64; 2] = [0.13, 0.21];
const CHORUS_MS: [f64; 4] = [7.0, 11.0, 13.0, 19.0];
const CHORUS_LFO_HZ: [f64; 4] = [0.31, 0.43, 0.57, 0.71];
const COMB_MS: [f64; 4] = [83.0, 109.0, 137.0, 167.0];

persist_mut!(MODAL: [[Biquad; 8]; 2] = [const { [const { Biquad::new() }; 8] }; 2]);
persist_mut!(RING_LFO: [Lfo; 2] = [const { Lfo::new() }; 2]);
persist_mut!(CHORUS_DL: [[DelayLine<MAX_DL>; 4]; 2] = [const { [const { DelayLine::new() }; 4] }; 2]);
persist_mut!(CHORUS_LFO: [Lfo; 4] = [const { Lfo::new() }; 4]);
persist_mut!(COMBS: [[DelayLine<MAX_DL>; 4]; 2] = [const { [const { DelayLine::new() }; 4] }; 2]);
persist_mut!(COMB_LP: [[Biquad; 4]; 2] = [const { [const { Biquad::new() }; 4] }; 2]);
persist_mut!(COMB_FB_BUF: [[f64; 4]; 2] = [[0.0; 4]; 2]);

process! { ctx =>
    let sr = ctx.sample_rate() as f64;

    let bloom = ctx.param(BLOOM) as f64 / 100.0;
    let drift = ctx.param(DRIFT) as f64 / 100.0;
    let chorus = ctx.param(CHORUS) as f64 / 100.0;
    let garden = ctx.param(GARDEN) as f64 / 100.0;
    let mx = ctx.param(MIX) as f64;

    let modal_q = 10.0 + 20.0 * bloom;
    let mut modal_c: [BiquadCoeffs; 8] = [BiquadCoeffs::lowpass(1000.0, 0.707, sr); 8];
    for k in 0..8 {
        let mut f = FUNDAMENTAL * HARMONICS[k];
        if f > sr * 0.45 {
            f = sr * 0.45;
        }
        modal_c[k] = BiquadCoeffs::bandpass(f, modal_q, sr);
    }
    let comb_lpc = BiquadCoeffs::lowpass(3500.0, 0.707, sr);

    let nch = ctx.channels().min(2);

    let chorus_base: [f64; 4] = [
        CHORUS_MS[0] * 0.001 * sr,
        CHORUS_MS[1] * 0.001 * sr,
        CHORUS_MS[2] * 0.001 * sr,
        CHORUS_MS[3] * 0.001 * sr,
    ];
    let chorus_depth = (1.5 + 4.5 * chorus) * 0.001 * sr;
    let comb_d: [f64; 4] = [
        COMB_MS[0] * 0.001 * sr,
        COMB_MS[1] * 0.001 * sr,
        COMB_MS[2] * 0.001 * sr,
        COMB_MS[3] * 0.001 * sr,
    ];
    let comb_fb_amt = 0.55 + 0.30 * garden;

    let modal_gain: f64 = 1.0 / 8.0;
    let ring_depth = 0.5 + 0.5 * drift;

    MODAL.with_mut(|modal| {
        RING_LFO.with_mut(|ring_lfo| {
            CHORUS_DL.with_mut(|chorus_dl| {
                CHORUS_LFO.with_mut(|chorus_lfo| {
                    COMBS.with_mut(|combs| {
                        COMB_LP.with_mut(|comb_lp| {
                            COMB_FB_BUF.with_mut(|comb_fb_buf| {
                                for k in 0..2 {
                                    ring_lfo[k].init(sr, RING_HZ[k]);
                                }
                                for k in 0..4 {
                                    chorus_lfo[k].init(sr, CHORUS_LFO_HZ[k]);
                                }

                                for ch in 0..nch {
                                    for k in 0..8 {
                                        modal[ch][k].set_coeffs(modal_c[k]);
                                    }
                                    for k in 0..4 {
                                        comb_lp[ch][k].set_coeffs(comb_lpc);
                                    }
                                }

                                for f in 0..ctx.frames() {
                                    let r0 = ring_lfo[0].tick();
                                    let r1 = ring_lfo[1].tick();
                                    let c0 = chorus_lfo[0].tick();
                                    let c1 = chorus_lfo[1].tick();
                                    let c2 = chorus_lfo[2].tick();
                                    let c3 = chorus_lfo[3].tick();
                                    let cd = [c0, c1, c2, c3];

                                    let carrier = (1.0 - ring_depth) + ring_depth * 0.5 * (r0 + r1);

                                    for ch in 0..nch {
                                        let dry = ctx.input(ch, f) as f64;

                                        // Stage A: 8-partial just-intonation modal bank
                                        let mut modal_sum: f64 = 0.0;
                                        for k in 0..8 {
                                            modal_sum += modal[ch][k].process_sample(dry);
                                        }
                                        modal_sum *= modal_gain;

                                        // Stage B: ring modulation with sub-Hz carrier
                                        let rung = modal_sum * carrier;

                                        // Stage C: 4-voice chorus
                                        let mut chorus_sum: f64 = 0.0;
                                        for k in 0..4 {
                                            let mut d = chorus_base[k] + cd[k] * chorus_depth;
                                            if d < 1.0 {
                                                d = 1.0;
                                            }
                                            chorus_dl[ch][k].write(rung as f32);
                                            chorus_sum += chorus_dl[ch][k].read(d) as f64;
                                        }
                                        chorus_sum *= 0.25;

                                        // Stage D: 4-comb spacious reverb
                                        let mut tail_sum: f64 = 0.0;
                                        for k in 0..4 {
                                            let f_in = comb_lp[ch][k].process_sample(comb_fb_buf[ch][k]);
                                            combs[ch][k].write((chorus_sum + comb_fb_amt * f_in) as f32);
                                            comb_fb_buf[ch][k] = combs[ch][k].read(comb_d[k]) as f64;
                                            tail_sum += comb_fb_buf[ch][k];
                                        }
                                        tail_sum *= 0.25;

                                        let wet = chorus_sum + tail_sum;
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
}
