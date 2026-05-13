// Rusted Carousel — a derelict fairground organ playing a lopsided waltz.
//
// 5-voice calliope chorus (prime-spaced 9 / 13 / 17 / 23 / 29 ms base
// delays, each modulated by its own 0.17–0.41 Hz LFO — ±25¢-ish detune) →
// waltz amplitude LFO (1.2 Hz triangle shaped as |tri| to pulse in 3s) →
// pipe-pitch feedback comb at 110 Hz (~9.09 ms) → asymmetric tube-style
// tanh saturation → final mix.
//
// Distinct from Broken Fax Lullaby: metered waltz LFO rather than coprime
// square gating; detuned-organ texture. Distinct from Underwater Spy: the
// chorus itself is the rust/character, not a lush doubling effect.
//
// Params:
//   CALLIOPE (pct) — chorus depth
//   WALTZ    (pct) — waltz amplitude modulation depth
//   ORGAN    (pct) — pipe comb feedback
//   TUBE     (pct) — asymmetric tanh drive
//   MIX            — wet/dry blend

use conjuredsp::*;
params! {
    CALLIOPE = pct().default(60.0),
    WALTZ = pct().default(55.0),
    ORGAN = pct().default(50.0),
    TUBE = pct().default(45.0),
    MIX = mix().default(0.55),
}

const MAX_DL: usize = 10000;

const CHORUS_MS: [f64; 5] = [9.0, 13.0, 17.0, 23.0, 29.0];
const CHORUS_LFO_HZ: [f64; 5] = [0.17, 0.23, 0.29, 0.37, 0.41];
const WALTZ_HZ: f64 = 1.2;
const PIPE_HZ: f64 = 110.0;

persist_mut!(CHORUS_DL: [[DelayLine<MAX_DL>; 5]; 2] = [const { [const { DelayLine::new() }; 5] }; 2]);
persist_mut!(CHORUS_LFO: [Lfo; 5] = [const { Lfo::new() }; 5]);
persist_mut!(WALTZ_LFO: Lfo = Lfo::new());
persist_mut!(PIPE_DL: [DelayLine<MAX_DL>; 2] = [const { DelayLine::new() }; 2]);
persist_mut!(PIPE_FB: [f64; 2] = [0.0; 2]);
persist_mut!(PIPE_LP: [Biquad; 2] = [const { Biquad::new() }; 2]);

process! { ctx =>
    let sr = ctx.sample_rate() as f64;

    let calliope = ctx.param(CALLIOPE) as f64 / 100.0;
    let waltz = ctx.param(WALTZ) as f64 / 100.0;
    let organ = ctx.param(ORGAN) as f64 / 100.0;
    let tube = ctx.param(TUBE) as f64 / 100.0;
    let mx = ctx.param(MIX) as f64;

    let pipe_lpc = BiquadCoeffs::lowpass(2800.0, 0.707, sr);

    let nch = ctx.channels().min(2);

    let chorus_base: [f64; 5] = [
        CHORUS_MS[0] * 0.001 * sr,
        CHORUS_MS[1] * 0.001 * sr,
        CHORUS_MS[2] * 0.001 * sr,
        CHORUS_MS[3] * 0.001 * sr,
        CHORUS_MS[4] * 0.001 * sr,
    ];
    let chorus_depth = (0.8 + 1.8 * calliope) * 0.001 * sr;
    let waltz_depth = 0.65 * waltz;
    let pipe_d = (1.0 / PIPE_HZ) * sr;
    let pipe_fb_amt = 0.50 + 0.40 * organ;

    let drive_pos = 1.0 + 3.0 * tube;
    let drive_neg = 1.0 + 1.5 * tube;

    let chorus_gain: f64 = 1.0 / 5.0;

    CHORUS_DL.with_mut(|chorus_dl| {
        CHORUS_LFO.with_mut(|chorus_lfo| {
            WALTZ_LFO.with_mut(|waltz_lfo| {
                PIPE_DL.with_mut(|pipe_dl| {
                    PIPE_FB.with_mut(|pipe_fb| {
                        PIPE_LP.with_mut(|pipe_lp| {
                            for k in 0..5 {
                                chorus_lfo[k].init(sr, CHORUS_LFO_HZ[k]);
                            }
                            waltz_lfo.init(sr, WALTZ_HZ);
                            waltz_lfo.set_waveform(Waveform::Triangle);

                            for ch in 0..nch {
                                pipe_lp[ch].set_coeffs(pipe_lpc);
                            }

                            for f in 0..ctx.frames() {
                                let cm: [f64; 5] = [
                                    chorus_lfo[0].tick(),
                                    chorus_lfo[1].tick(),
                                    chorus_lfo[2].tick(),
                                    chorus_lfo[3].tick(),
                                    chorus_lfo[4].tick(),
                                ];
                                let w_tri = waltz_lfo.tick();
                                let waltz_mod = (1.0 - waltz_depth) + waltz_depth * w_tri.abs();

                                for ch in 0..nch {
                                    let dry = ctx.input(ch, f) as f64;

                                    let mut chorus_sum: f64 = 0.0;
                                    for k in 0..5 {
                                        let mut d = chorus_base[k] + cm[k] * chorus_depth;
                                        if d < 1.0 {
                                            d = 1.0;
                                        }
                                        chorus_dl[ch][k].write(dry as f32);
                                        chorus_sum += chorus_dl[ch][k].read(d) as f64;
                                    }
                                    chorus_sum *= chorus_gain;

                                    let pulsed = chorus_sum * waltz_mod;

                                    let f_in = pipe_lp[ch].process_sample(pipe_fb[ch]);
                                    pipe_dl[ch].write((pulsed + pipe_fb_amt * f_in) as f32);
                                    pipe_fb[ch] = pipe_dl[ch].read(pipe_d) as f64;

                                    let x = pulsed + pipe_fb[ch] * 0.6;
                                    let wet = if x >= 0.0 {
                                        (x * drive_pos).tanh() / drive_pos
                                    } else {
                                        (x * drive_neg).tanh() / drive_neg
                                    };

                                    ctx.set_output(ch, f, (dry * (1.0 - mx) + wet * mx) as f32);
                                }
                            }
                        });
                    });
                });
            });
        });
    });
}
