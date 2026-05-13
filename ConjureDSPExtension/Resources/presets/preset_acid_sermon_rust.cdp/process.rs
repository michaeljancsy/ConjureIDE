// Acid Sermon — a televangelist sermon corroding through the speaker.
//
// Sin-based wavefolder (y = sin(π/2 · x · drive) — folds rather than soft-
// saturates when driven past unity) → 3 static formant peaks (700 / 1400 /
// 2500 Hz) whose amplitudes are modulated by 3 sub-Hz LFOs (0.11 / 0.17 /
// 0.23 Hz) → midrange presence peak (1800 Hz, +8 dB) → hard clip ceiling
// (aggressive clipping, NOT soft tanh) → dry no-reverb close space → mix.
//
// First preset using a wavefolder and hard clip instead of soft tanh;
// aggressive dry mids instead of a reverb tail. The corrosion IS the sound.
//
// Params:
//   FOLD     (pct) — wavefolder drive
//   SERMON   (pct) — formant amplitude modulation depth
//   PRESENCE (pct) — midrange presence peak gain
//   CRUST    (pct) — hard clip ceiling (lower → more clipping)
//   MIX            — wet/dry blend

use conjuredsp::*;
params! {
    FOLD = pct().default(55.0),
    SERMON = pct().default(50.0),
    PRESENCE = pct().default(60.0),
    CRUST = pct().default(55.0),
    MIX = mix().default(0.6),
}

const FORMANT_HZ: [f64; 3] = [700.0, 1400.0, 2500.0];
const FORMANT_LFO_HZ: [f64; 3] = [0.11, 0.17, 0.23];
const PRESENCE_HZ: f64 = 1800.0;

persist_mut!(FORMANT: [[Biquad; 3]; 2] = [[Biquad::new(); 3]; 2]);
persist_mut!(FORMANT_LFO: [Lfo; 3] = [Lfo::new(); 3]);
persist_mut!(PRESENCE_F: [Biquad; 2] = [Biquad::new(); 2]);

process! { ctx =>
    let sr = ctx.sample_rate() as f64;

    let fold = ctx.param(FOLD) as f64 / 100.0;
    let sermon = ctx.param(SERMON) as f64 / 100.0;
    let presence = ctx.param(PRESENCE) as f64 / 100.0;
    let crust = ctx.param(CRUST) as f64 / 100.0;
    let mx = ctx.param(MIX) as f64;

    let formant_c: [BiquadCoeffs; 3] = [
        BiquadCoeffs::peak(FORMANT_HZ[0], 4.0, 8.0, sr),
        BiquadCoeffs::peak(FORMANT_HZ[1], 4.0, 8.0, sr),
        BiquadCoeffs::peak(FORMANT_HZ[2], 4.0, 8.0, sr),
    ];
    let presence_c = BiquadCoeffs::peak(PRESENCE_HZ, 2.5, 3.0 + 6.0 * presence, sr);

    let nch = ctx.channels().min(2);

    let drive = 1.0 + 5.0 * fold;
    let fold_scale = core::f64::consts::PI * 0.5 * drive;
    let formant_depth = 0.6 * sermon;
    let clip_ceil = 1.0 - 0.7 * crust;

    FORMANT.with_mut(|formant| {
        FORMANT_LFO.with_mut(|formant_lfo| {
            PRESENCE_F.with_mut(|presence_f| {
                for k in 0..3 {
                    formant_lfo[k].init(sr, FORMANT_LFO_HZ[k]);
                }

                for ch in 0..nch {
                    for k in 0..3 {
                        formant[ch][k].set_coeffs(formant_c[k]);
                    }
                    presence_f[ch].set_coeffs(presence_c);
                }

                for f in 0..ctx.frames() {
                    let lm: [f64; 3] = [
                        formant_lfo[0].tick(),
                        formant_lfo[1].tick(),
                        formant_lfo[2].tick(),
                    ];
                    let fm: [f64; 3] = [
                        (1.0 - formant_depth) + formant_depth * (0.5 + 0.5 * lm[0]),
                        (1.0 - formant_depth) + formant_depth * (0.5 + 0.5 * lm[1]),
                        (1.0 - formant_depth) + formant_depth * (0.5 + 0.5 * lm[2]),
                    ];

                    for ch in 0..nch {
                        let dry = ctx.input(ch, f) as f64;

                        let folded = (dry * fold_scale).sin();

                        let f0 = formant[ch][0].process_sample(folded) * fm[0];
                        let f1 = formant[ch][1].process_sample(folded) * fm[1];
                        let f2 = formant[ch][2].process_sample(folded) * fm[2];
                        let voiced = (f0 + f1 + f2) / 3.0;

                        let presenced = presence_f[ch].process_sample(voiced);

                        let wet = if presenced > clip_ceil {
                            clip_ceil
                        } else if presenced < -clip_ceil {
                            -clip_ceil
                        } else {
                            presenced
                        };

                        ctx.set_output(ch, f, (dry * (1.0 - mx) + wet * mx) as f32);
                    }
                }
            });
        });
    });
}
