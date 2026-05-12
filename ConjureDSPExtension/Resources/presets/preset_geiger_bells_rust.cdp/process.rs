// Geiger Bells — radioactive clicks blossoming into bell tones.
//
// Deterministic stochastic impulse train (countdown sequence at 8 prime-ish
// inter-click distances scaled by density) → each impulse strikes a 4-partial
// harmonic bell resonator bank (440 / 880 / 1320 / 1760 Hz high-Q bandpass)
// → soft sub-pad bed derived from rectified input (80 Hz LP) → final mix.
//
// The source is the stochastic impulse generator, NOT the input audio — the
// bells blossom independently of what's playing. Distinct from all previous
// presets where the input drives the resonators.
//
// Params:
//   DENSITY (pct) — click rate (fewer → more)
//   SHIMMER (pct) — bell resonator Q (18 → 45)
//   BLOOM   (pct) — bell level
//   SUBPAD  (pct) — sub-bass bed level
//   MIX           — wet/dry blend

// Falls back to raw `static mut` under the plan's Plan B (see
// plans/an-ai-had-this-starry-moler.md). Each preset on this fallback
// gets a per-preset `persist!()` / `persist_buf!()` migration over time;
// the lock-in test ConjureDSPLogicTests/PresetEntryPointLockInTests carries
// the live allow-list and removes a name as each preset gets migrated.
#![allow(static_mut_refs)]

use conjuredsp::*;
params! {
    DENSITY = pct().default(55.0),
    SHIMMER = pct().default(60.0),
    BLOOM = pct().default(60.0),
    SUBPAD = pct().default(45.0),
    MIX = mix().default(0.55),
}

const BELL_HZ: [f64; 4] = [440.0, 880.0, 1320.0, 1760.0];
const BELL_PARTIAL_GAIN: [f64; 4] = [1.0, 0.7, 0.5, 0.35];
const CLICK_MS: [f64; 8] = [77.0, 113.0, 59.0, 89.0, 137.0, 71.0, 103.0, 61.0];

static mut BELL: [[Biquad; 4]; 2] = [[Biquad::new(); 4]; 2];
static mut SUB_LP: [Biquad; 2] = [Biquad::new(); 2];
static mut CLICK_IX: usize = 0;
static mut COUNTDOWN: f64 = 0.0;

process! { ctx =>
    let sr = ctx.sample_rate() as f64;

    unsafe {
        let density = ctx.param(DENSITY) as f64 / 100.0;
        let shimmer = ctx.param(SHIMMER) as f64 / 100.0;
        let bloom = ctx.param(BLOOM) as f64 / 100.0;
        let subpad = ctx.param(SUBPAD) as f64 / 100.0;
        let mx = ctx.param(MIX) as f64;

        let bell_q = 18.0 + 27.0 * shimmer;
        let bell_c: [BiquadCoeffs; 4] = [
            BiquadCoeffs::bandpass(BELL_HZ[0], bell_q, sr),
            BiquadCoeffs::bandpass(BELL_HZ[1], bell_q, sr),
            BiquadCoeffs::bandpass(BELL_HZ[2], bell_q, sr),
            BiquadCoeffs::bandpass(BELL_HZ[3], bell_q, sr),
        ];
        let sub_lpc = BiquadCoeffs::lowpass(80.0, 0.707, sr);
        let nch = ctx.channels().min(2);
        for ch in 0..nch {
            for k in 0..4 {
                BELL[ch][k].set_coeffs(bell_c[k]);
            }
            SUB_LP[ch].set_coeffs(sub_lpc);
        }

        let period_scale = 2.2 - 1.8 * density;
        let bell_gain = 2.0 + 4.0 * bloom;
        let sub_gain = 0.6 + 1.2 * subpad;

        for f in 0..ctx.frames() {
            COUNTDOWN -= 1.0;
            let mut impulse: f64 = 0.0;
            if COUNTDOWN <= 0.0 {
                impulse = 1.0;
                let next_ms = CLICK_MS[CLICK_IX] * period_scale;
                COUNTDOWN = next_ms * 0.001 * sr;
                CLICK_IX = (CLICK_IX + 1) % 8;
            }

            for ch in 0..nch {
                let dry = ctx.input(ch, f) as f64;

                let sub_voice = SUB_LP[ch].process_sample(dry.abs()) * sub_gain;

                let mut bell_sum: f64 = 0.0;
                for k in 0..4 {
                    bell_sum += BELL[ch][k].process_sample(impulse) * BELL_PARTIAL_GAIN[k];
                }
                let bell_voice = bell_sum * bell_gain;

                let wet = bell_voice + sub_voice;
                ctx.set_output(ch, f, (dry * (1.0 - mx) + wet * mx) as f32);
            }
        }
    }
}
