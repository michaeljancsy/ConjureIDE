// Plague Doctor — medieval mask, breath rasping behind formant chambers.
//
// 3 cascaded nasal/throat peak EQs (250 / 700 / 2200 Hz, Q=4, +9 dB) → slow
// 0.3 Hz triangle "breath" envelope (asymmetric, modulates amplitude ±60%)
// → midrange presence peak EQ (1200 Hz, Q=2, +6 dB) → soft tanh saturation
// → close dry space (no reverb) → final mix.
//
// Distinct from Ghost Choir: dry/close formant treatment with nasal/throat
// vowel cluster vs Ghost Choir's wet/wide "ah" formants. Breath envelope is
// an expressive control rather than decorative modulation.
//
// Controls:
//   MASK     (pct) — nasal formant cluster gain
//   BREATH   (pct) — breath envelope depth
//   RASP     (pct) — tanh saturation drive
//   PRESENCE (pct) — midrange presence peak gain
//   MIX            — wet/dry blend

use conjuredsp::*;
params! {
    MASK = pct().default(65.0),
    BREATH = pct().default(55.0),
    RASP = pct().default(50.0),
    PRESENCE = pct().default(55.0),
    MIX = mix().default(0.6),
}

const FORMANT_HZ: [f64; 3] = [250.0, 700.0, 2200.0];
const BREATH_HZ: f64 = 0.3;
const PRESENCE_HZ: f64 = 1200.0;

persist_mut!(FORMANT: [[Biquad; 3]; 2] = [const { [const { Biquad::new() }; 3] }; 2]);
persist_mut!(PRESENCE_F: [Biquad; 2] = [const { Biquad::new() }; 2]);
persist_mut!(BREATH_LFO: Lfo = Lfo::new());

process! { ctx =>
    let sr = ctx.sample_rate() as f64;

    let mask = ctx.param(MASK) as f64 / 100.0;
    let breath = ctx.param(BREATH) as f64 / 100.0;
    let rasp = ctx.param(RASP) as f64 / 100.0;
    let presence = ctx.param(PRESENCE) as f64 / 100.0;
    let mx = ctx.param(MIX) as f64;

    let formant_gain = 4.0 + 8.0 * mask;
    let formant_c: [BiquadCoeffs; 3] = [
        BiquadCoeffs::peak(FORMANT_HZ[0], 4.0, formant_gain, sr),
        BiquadCoeffs::peak(FORMANT_HZ[1], 4.0, formant_gain, sr),
        BiquadCoeffs::peak(FORMANT_HZ[2], 4.0, formant_gain, sr),
    ];
    let presence_gain = 2.0 + 6.0 * presence;
    let presence_c = BiquadCoeffs::peak(PRESENCE_HZ, 2.0, presence_gain, sr);

    let nch = ctx.channels().min(2);

    let breath_depth = 0.60 * breath;
    let drive = 1.0 + 3.5 * rasp;

    FORMANT.with_mut(|formant| {
        PRESENCE_F.with_mut(|presence_f| {
            BREATH_LFO.with_mut(|breath_lfo| {
                breath_lfo.init(sr, BREATH_HZ);
                breath_lfo.set_waveform(Waveform::Triangle);

                for ch in 0..nch {
                    for k in 0..3 {
                        formant[ch][k].set_coeffs(formant_c[k]);
                    }
                    presence_f[ch].set_coeffs(presence_c);
                }

                for f in 0..ctx.frames() {
                    let tri = breath_lfo.tick();
                    let env = 0.5 + 0.5 * tri;
                    let breath_mod = (1.0 - breath_depth) + breath_depth * env * env;

                    for ch in 0..nch {
                        let dry = ctx.input(ch, f) as f64;

                        let mut x = dry;
                        for k in 0..3 {
                            x = formant[ch][k].process_sample(x);
                        }

                        x = presence_f[ch].process_sample(x);

                        x *= breath_mod;

                        let wet = (x * drive).tanh() / drive;

                        ctx.set_output(ch, f, (dry * (1.0 - mx) + wet * mx) as f32);
                    }
                }
            });
        });
    });
}
