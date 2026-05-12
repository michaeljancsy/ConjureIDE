// Sun-Baked Cassette — cassette tape left in the sun for 30 years.
//
// Wow + flutter modulated delay → frequency-dependent + asymmetric tanh
// saturation → tone shaping shelves → print-through pre-echo → tape echo
// (LP in feedback) → head-wear feedback comb → final mix.
//
// Params:
//   WOW     (ms)  — slow pitch drift depth (0–6)
//   FLUTTER (ms)  — fast warble depth (0–3)
//   WEAR    (pct) — drives saturation amount, 0=clean / 100=destroyed
//   TONE    (pct) — high-frequency rolloff amount (0=bright / 100=dull)
//   MIX           — wet/dry blend

use conjuredsp::*;
params! {
    WOW = time_ms().min(0.0).max(6.0).default(3.0),
    FLUTTER = time_ms().min(0.0).max(3.0).default(1.2),
    WEAR = pct().default(45.0),
    TONE = pct().default(50.0),
    MIX = mix().default(0.6),
}

const MAX_DL: usize = 24000;
const WF_BASE_MS: f64 = 8.0;
const PRINT_MS: f64 = 150.0;
const ECHO_MS: f64 = 280.0;
const COMB_MS: f64 = 0.7;

persist_buf!(WF: [DelayLine<MAX_DL>; 2] = [DelayLine::new(); 2]);
persist_buf!(PRE_HS: [Biquad; 2] = [Biquad::new(); 2]);
persist_buf!(DE_HS: [Biquad; 2] = [Biquad::new(); 2]);
persist_buf!(LO_SH: [Biquad; 2] = [Biquad::new(); 2]);
persist_buf!(HI_SH: [Biquad; 2] = [Biquad::new(); 2]);
persist_buf!(PRINT_DL: [DelayLine<MAX_DL>; 2] = [DelayLine::new(); 2]);
persist_buf!(PRINT_LP: [Biquad; 2] = [Biquad::new(); 2]);
persist_buf!(ECHO_DL: [DelayLine<MAX_DL>; 2] = [DelayLine::new(); 2]);
persist_buf!(ECHO_LP: [Biquad; 2] = [Biquad::new(); 2]);
persist_buf!(ECHO_FB: [f64; 2] = [0.0; 2]);
persist_buf!(COMB_DL: [DelayLine<MAX_DL>; 2] = [DelayLine::new(); 2]);
persist_buf!(COMB_FB: [f64; 2] = [0.0; 2]);
persist_buf!(LFO_WOW: Lfo = Lfo::new());
persist_buf!(LFO_FLUTTER: Lfo = Lfo::new());

process! { ctx =>
    let sr = ctx.sample_rate() as f64;

    let wow_ms = ctx.param(WOW) as f64;
    let flutter_ms = ctx.param(FLUTTER) as f64;
    let wear = ctx.param(WEAR) as f64 / 100.0;
    let tone = ctx.param(TONE) as f64 / 100.0;
    let mx = ctx.param(MIX) as f64;

    let pre_hsc = BiquadCoeffs::highshelf(5000.0, 0.707, 6.0, sr);
    let de_hsc = BiquadCoeffs::highshelf(5000.0, 0.707, -9.0, sr);
    let lo_shc = BiquadCoeffs::lowshelf(120.0, 0.707, 3.0, sr);
    let hi_shc = BiquadCoeffs::highshelf(8000.0, 0.707, -12.0 * tone, sr);
    let print_lpc = BiquadCoeffs::lowpass(1500.0, 0.707, sr);
    let echo_lpc = BiquadCoeffs::lowpass(3000.0, 0.707, sr);

    let nch = ctx.channels().min(2);

    let drive_pos = 1.0 + wear * 2.5;
    let drive_neg = 1.0 + wear * 1.6;

    let base_d = WF_BASE_MS * 0.001 * sr;
    let wow_depth = wow_ms * 0.001 * sr;
    let flutter_depth = flutter_ms * 0.001 * sr;
    let print_d = PRINT_MS * 0.001 * sr;
    let echo_d = ECHO_MS * 0.001 * sr;
    let comb_d = (COMB_MS * 0.001 * sr).max(1.0);

    let print_gain: f64 = 0.04;
    let echo_fb_amt: f64 = 0.4;
    let comb_fb_amt: f64 = 0.35;

    WF.with_mut(|wf| {
        PRE_HS.with_mut(|pre_hs| {
            DE_HS.with_mut(|de_hs| {
                LO_SH.with_mut(|lo_sh| {
                    HI_SH.with_mut(|hi_sh| {
                        PRINT_DL.with_mut(|print_dl| {
                            PRINT_LP.with_mut(|print_lp| {
                                ECHO_DL.with_mut(|echo_dl| {
                                    ECHO_LP.with_mut(|echo_lp| {
                                        ECHO_FB.with_mut(|echo_fb| {
                                            COMB_DL.with_mut(|comb_dl| {
                                                COMB_FB.with_mut(|comb_fb| {
                                                    LFO_WOW.with_mut(|lfo_wow| {
                                                        LFO_FLUTTER.with_mut(|lfo_flutter| {
                                                            lfo_wow.init(sr, 0.5);
                                                            lfo_flutter.init(sr, 7.0);

                                                            for ch in 0..nch {
                                                                pre_hs[ch].set_coeffs(pre_hsc);
                                                                de_hs[ch].set_coeffs(de_hsc);
                                                                lo_sh[ch].set_coeffs(lo_shc);
                                                                hi_sh[ch].set_coeffs(hi_shc);
                                                                print_lp[ch].set_coeffs(print_lpc);
                                                                echo_lp[ch].set_coeffs(echo_lpc);
                                                            }

                                                            for f in 0..ctx.frames() {
                                                                let wlfo = lfo_wow.tick();
                                                                let flfo = lfo_flutter.tick();
                                                                let d = (base_d + wlfo * wow_depth + flfo * flutter_depth).max(1.0);

                                                                for ch in 0..nch {
                                                                    let dry = ctx.input(ch, f) as f64;

                                                                    // Stage A: wow + flutter modulated delay
                                                                    wf[ch].write(dry as f32);
                                                                    let mut x = wf[ch].read(d) as f64;

                                                                    // Stage B: pre-emphasis highshelf
                                                                    x = pre_hs[ch].process_sample(x);

                                                                    // Stage C: asymmetric tanh saturation
                                                                    if x > 0.0 {
                                                                        x = (x * drive_pos).tanh();
                                                                    } else {
                                                                        x = (x * drive_neg).tanh();
                                                                    }

                                                                    // Stage D: de-emphasis highshelf
                                                                    x = de_hs[ch].process_sample(x);

                                                                    // Stage E: tone shaping (warmth + HF rolloff)
                                                                    x = lo_sh[ch].process_sample(x);
                                                                    x = hi_sh[ch].process_sample(x);

                                                                    // Stage F: print-through pre-echo (lowpassed delayed dry)
                                                                    print_dl[ch].write(dry as f32);
                                                                    let mut print_tap = print_dl[ch].read(print_d) as f64;
                                                                    print_tap = print_lp[ch].process_sample(print_tap);
                                                                    x = x + print_tap * print_gain;

                                                                    // Stage G: tape echo (LP in feedback)
                                                                    let eflt = echo_lp[ch].process_sample(echo_fb[ch]);
                                                                    echo_dl[ch].write((x + echo_fb_amt * eflt) as f32);
                                                                    echo_fb[ch] = echo_dl[ch].read(echo_d) as f64;
                                                                    x = x + 0.5 * echo_fb[ch];

                                                                    // Stage H: head-wear feedback comb
                                                                    comb_dl[ch].write((x + comb_fb_amt * comb_fb[ch]) as f32);
                                                                    comb_fb[ch] = comb_dl[ch].read(comb_d) as f64;
                                                                    x = x + 0.3 * comb_fb[ch];

                                                                    ctx.set_output(ch, f, (dry * (1.0 - mx) + x * mx) as f32);
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
                        });
                    });
                });
            });
        });
    });
}
