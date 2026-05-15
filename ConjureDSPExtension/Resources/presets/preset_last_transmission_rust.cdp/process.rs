// Last Transmission — a dying SOS broadcast through static.
//
// Narrow telegraph bandpass (800 Hz center, high Q) → dropout envelope
// (3 slow LFOs at 0.19 / 0.43 / 0.8 Hz summed; when sum falls below a
// dropout-scaled threshold the signal goes silent) → soft tanh fuzz
// scaled by the dropout envelope → small far reverb (2 allpass + short
// comb) → final mix.
//
// Distinct from Alien Radio: intimate, decaying single-channel transmission
// rather than wide stereo broadcast. First preset where dropout density is
// the primary expressive control.
//
// Controls:
//   RADIO    (pct) — bandpass narrowness (Q)
//   DROPOUT  (pct) — dropout density
//   FUZZ     (pct) — tanh saturation drive
//   DISTANCE (pct) — far-reverb amount
//   MIX            — wet/dry blend

use conjuredsp::*;
params! {
    RADIO = pct().default(70.0),
    DROPOUT = pct().default(55.0),
    FUZZ = pct().default(50.0),
    DISTANCE = pct().default(40.0),
    MIX = mix().default(0.6),
}

const MAX_DL: usize = 16000;

const BP_HZ: f64 = 800.0;
const DROPOUT_HZ: [f64; 3] = [0.19, 0.43, 0.8];
const AP_MS: [f64; 2] = [5.3, 7.9];
const AP_G: f64 = 0.5;
const COMB_MS: f64 = 67.0;

persist_mut!(BP: [Biquad; 2] = [const { Biquad::new() }; 2]);
persist_mut!(DROPOUT_LFO: [Lfo; 3] = [const { Lfo::new() }; 3]);
persist_mut!(AP: [[DelayLine<MAX_DL>; 2]; 2] = [const { [const { DelayLine::new() }; 2] }; 2]);
persist_mut!(APS: [[f64; 2]; 2] = [[0.0; 2]; 2]);
persist_mut!(COMB: [DelayLine<MAX_DL>; 2] = [const { DelayLine::new() }; 2]);
persist_mut!(COMB_FB: [f64; 2] = [0.0; 2]);
persist_mut!(COMB_LP: [Biquad; 2] = [const { Biquad::new() }; 2]);

process! { ctx =>
    let sr = ctx.sample_rate() as f64;

    let radio = ctx.param(RADIO) as f64 / 100.0;
    let dropout = ctx.param(DROPOUT) as f64 / 100.0;
    let fuzz = ctx.param(FUZZ) as f64 / 100.0;
    let distance = ctx.param(DISTANCE) as f64 / 100.0;
    let mx = ctx.param(MIX) as f64;

    let bp_q = 4.0 + 12.0 * radio;
    let bp_c = BiquadCoeffs::bandpass(BP_HZ, bp_q, sr);
    let comb_lpc = BiquadCoeffs::lowpass(1600.0, 0.707, sr);

    let nch = ctx.channels().min(2);

    let ap_d: [f64; 2] = [
        (AP_MS[0] * 0.001 * sr).max(1.0),
        (AP_MS[1] * 0.001 * sr).max(1.0),
    ];
    let comb_d = COMB_MS * 0.001 * sr;
    let comb_fb_amt = 0.45 + 0.40 * distance;

    let drive = 1.0 + 5.0 * fuzz;
    let drop_thresh = -0.4 + 1.2 * dropout;

    BP.with_mut(|bp| {
        DROPOUT_LFO.with_mut(|dropout_lfo| {
            AP.with_mut(|ap| {
                APS.with_mut(|aps| {
                    COMB.with_mut(|comb| {
                        COMB_FB.with_mut(|comb_fb| {
                            COMB_LP.with_mut(|comb_lp| {
                                for k in 0..3 {
                                    dropout_lfo[k].init(sr, DROPOUT_HZ[k]);
                                }

                                for ch in 0..nch {
                                    bp[ch].set_coeffs(bp_c);
                                    comb_lp[ch].set_coeffs(comb_lpc);
                                }

                                for f in 0..ctx.frames() {
                                    let d0 = dropout_lfo[0].tick();
                                    let d1 = dropout_lfo[1].tick();
                                    let d2 = dropout_lfo[2].tick();
                                    let drop_env = (d0 + d1 + d2) / 3.0;
                                    let gate = drop_env - drop_thresh;
                                    let gate_val = if gate < 0.0 {
                                        0.0
                                    } else if gate > 0.3 {
                                        1.0
                                    } else {
                                        gate / 0.3
                                    };

                                    for ch in 0..nch {
                                        let dry = ctx.input(ch, f) as f64;

                                        let filtered = bp[ch].process_sample(dry);

                                        let gated = filtered * gate_val;

                                        let fuzzed = (gated * drive).tanh() / drive;

                                        let mut sig = fuzzed;
                                        for k in 0..2 {
                                            let vd = aps[ch][k];
                                            let vn = sig + AP_G * vd;
                                            ap[ch][k].write(vn as f32);
                                            aps[ch][k] = ap[ch][k].read(ap_d[k]) as f64;
                                            sig = vd - AP_G * vn;
                                        }

                                        let f_in = comb_lp[ch].process_sample(comb_fb[ch]);
                                        comb[ch].write((sig + comb_fb_amt * f_in) as f32);
                                        comb_fb[ch] = comb[ch].read(comb_d) as f64;

                                        let wet = fuzzed + sig * 0.4 + comb_fb[ch] * 0.5;
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
