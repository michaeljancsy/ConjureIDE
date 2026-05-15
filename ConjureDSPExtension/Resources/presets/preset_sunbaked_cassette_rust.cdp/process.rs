// Sun-Baked Cassette — cassette tape left in the sun for 30 years.
//
// Wow + flutter modulated delay → frequency-dependent + asymmetric tanh
// saturation → tone shaping shelves → print-through pre-echo → tape echo
// (LP in feedback) → head-wear feedback comb → final mix.
//
// Controls:
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

// Tape transport: wow + flutter modulated delay line and the two LFOs that
// drive it.
struct Transport {
    dl: [DelayLine<MAX_DL>; 2],
    lfo_wow: Lfo,
    lfo_flutter: Lfo,
}

// Pre- and de-emphasis highshelves bracketing the tanh saturation.
struct Emphasis {
    pre: [Biquad; 2],
    de: [Biquad; 2],
}

// Tone-shaping shelves: warmth lowshelf + HF rolloff highshelf. Named
// `Shelves` (not `Tone`) so the static doesn't clash with the `TONE`
// parameter index const.
struct Shelves {
    lo: [Biquad; 2],
    hi: [Biquad; 2],
}

// Print-through pre-echo: lowpassed delayed dry layer.
struct Print {
    dl: [DelayLine<MAX_DL>; 2],
    lp: [Biquad; 2],
}

// Tape echo with LP in the feedback loop.
struct Echo {
    dl: [DelayLine<MAX_DL>; 2],
    lp: [Biquad; 2],
    fb: [f64; 2],
}

// Head-wear feedback comb.
struct Comb {
    dl: [DelayLine<MAX_DL>; 2],
    fb: [f64; 2],
}

persist_mut!(TRANSPORT: Transport = Transport {
    dl: [const { DelayLine::new() }; 2],
    lfo_wow: Lfo::new(),
    lfo_flutter: Lfo::new(),
});
persist_mut!(EMPHASIS: Emphasis = Emphasis {
    pre: [const { Biquad::new() }; 2],
    de: [const { Biquad::new() }; 2],
});
persist_mut!(SHELVES: Shelves = Shelves {
    lo: [const { Biquad::new() }; 2],
    hi: [const { Biquad::new() }; 2],
});
persist_mut!(PRINT: Print = Print {
    dl: [const { DelayLine::new() }; 2],
    lp: [const { Biquad::new() }; 2],
});
persist_mut!(ECHO: Echo = Echo {
    dl: [const { DelayLine::new() }; 2],
    lp: [const { Biquad::new() }; 2],
    fb: [0.0; 2],
});
persist_mut!(COMB: Comb = Comb {
    dl: [const { DelayLine::new() }; 2],
    fb: [0.0; 2],
});

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

    TRANSPORT.with_mut(|transport| {
        EMPHASIS.with_mut(|emphasis| {
            SHELVES.with_mut(|shelves| {
                PRINT.with_mut(|print| {
                    ECHO.with_mut(|echo| {
                        COMB.with_mut(|comb| {
                            transport.lfo_wow.init(sr, 0.5);
                            transport.lfo_flutter.init(sr, 7.0);

                            for ch in 0..nch {
                                emphasis.pre[ch].set_coeffs(pre_hsc);
                                emphasis.de[ch].set_coeffs(de_hsc);
                                shelves.lo[ch].set_coeffs(lo_shc);
                                shelves.hi[ch].set_coeffs(hi_shc);
                                print.lp[ch].set_coeffs(print_lpc);
                                echo.lp[ch].set_coeffs(echo_lpc);
                            }

                            for f in 0..ctx.frames() {
                                let wlfo = transport.lfo_wow.tick();
                                let flfo = transport.lfo_flutter.tick();
                                let d = (base_d + wlfo * wow_depth + flfo * flutter_depth).max(1.0);

                                for ch in 0..nch {
                                    let dry = ctx.input(ch, f) as f64;

                                    // Stage A: wow + flutter modulated delay
                                    transport.dl[ch].write(dry as f32);
                                    let mut x = transport.dl[ch].read(d) as f64;

                                    // Stage B: pre-emphasis highshelf
                                    x = emphasis.pre[ch].process_sample(x);

                                    // Stage C: asymmetric tanh saturation
                                    if x > 0.0 {
                                        x = (x * drive_pos).tanh();
                                    } else {
                                        x = (x * drive_neg).tanh();
                                    }

                                    // Stage D: de-emphasis highshelf
                                    x = emphasis.de[ch].process_sample(x);

                                    // Stage E: tone shaping (warmth + HF rolloff)
                                    x = shelves.lo[ch].process_sample(x);
                                    x = shelves.hi[ch].process_sample(x);

                                    // Stage F: print-through pre-echo (lowpassed delayed dry)
                                    print.dl[ch].write(dry as f32);
                                    let mut print_tap = print.dl[ch].read(print_d) as f64;
                                    print_tap = print.lp[ch].process_sample(print_tap);
                                    x = x + print_tap * print_gain;

                                    // Stage G: tape echo (LP in feedback)
                                    let eflt = echo.lp[ch].process_sample(echo.fb[ch]);
                                    echo.dl[ch].write((x + echo_fb_amt * eflt) as f32);
                                    echo.fb[ch] = echo.dl[ch].read(echo_d) as f64;
                                    x = x + 0.5 * echo.fb[ch];

                                    // Stage H: head-wear feedback comb
                                    comb.dl[ch].write((x + comb_fb_amt * comb.fb[ch]) as f32);
                                    comb.fb[ch] = comb.dl[ch].read(comb_d) as f64;
                                    x = x + 0.3 * comb.fb[ch];

                                    ctx.set_output(ch, f, (dry * (1.0 - mx) + x * mx) as f32);
                                }
                            }
                        });
                    });
                });
            });
        });
    });
}
