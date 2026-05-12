// Mothlight — moths around a porchlight, erratic and bright.
//
// Fast random-walk tremolo (3 coprime LFOs at 5.7 / 8.3 / 12.1 Hz summed —
// chaotic, not periodic) → bright 3-bandpass cluster (1.8 / 3.2 / 5.5 kHz)
// → micro-pitch jitter via a single delay line modulated by a fast 17 Hz
// LFO → light octave-up shimmer (dual-tap pitch shifter) → final mix.
//
// Distinct from everything else in the set: high-frequency-emphasised,
// erratic, chaotic modulation; first use of summed-LFO random-walk and
// fast-LFO pitch jitter (distinct from Sun-Baked Cassette's slow wow).
//
// Params:
//   FLUTTER (pct) — tremolo depth
//   BRIGHT  (pct) — bandpass Q
//   JITTER  (pct) — pitch jitter depth
//   SHIMMER (pct) — octave-up shimmer level
//   MIX           — wet/dry blend

use conjuredsp::*;
params! {
    FLUTTER = pct().default(60.0),
    BRIGHT = pct().default(55.0),
    JITTER = pct().default(45.0),
    SHIMMER = pct().default(40.0),
    MIX = mix().default(0.55),
}

const MAX_DL: usize = 20000;

const TREM_HZ: [f64; 3] = [5.7, 8.3, 12.1];
const BP_HZ: [f64; 3] = [1800.0, 3200.0, 5500.0];
const JITTER_LFO_HZ: f64 = 17.0;
const JITTER_BASE_MS: f64 = 4.0;
const SHIFT_BASE_MS: f64 = 40.0;
const GRAIN_MS: f64 = 50.0;

static mut TREM_LFO: [Lfo; 3] = [Lfo::new(); 3];
static mut BP: [[Biquad; 3]; 2] = [[Biquad::new(); 3]; 2];
static mut JITTER_DL: [DelayLine<MAX_DL>; 2] = [DelayLine::new(); 2];
static mut JITTER_LFO: Lfo = Lfo::new();
static mut SHIFT_DL: [DelayLine<MAX_DL>; 2] = [DelayLine::new(); 2];
static mut GRAIN_PHASE: f64 = 0.0;

process! { ctx =>
    let sr = ctx.sample_rate() as f64;

    unsafe {
        let flutter = ctx.param(FLUTTER) as f64 / 100.0;
        let bright = ctx.param(BRIGHT) as f64 / 100.0;
        let jitter = ctx.param(JITTER) as f64 / 100.0;
        let shimmer = ctx.param(SHIMMER) as f64 / 100.0;
        let mx = ctx.param(MIX) as f64;

        let bp_q = 3.0 + 7.0 * bright;
        let bp_c: [BiquadCoeffs; 3] = [
            BiquadCoeffs::bandpass(BP_HZ[0], bp_q, sr),
            BiquadCoeffs::bandpass(BP_HZ[1], bp_q, sr),
            BiquadCoeffs::bandpass(BP_HZ[2], bp_q, sr),
        ];

        for k in 0..3 {
            TREM_LFO[k].init(sr, TREM_HZ[k]);
        }
        JITTER_LFO.init(sr, JITTER_LFO_HZ);

        let nch = ctx.channels().min(2);
        for ch in 0..nch {
            for k in 0..3 {
                BP[ch][k].set_coeffs(bp_c[k]);
            }
        }

        let trem_depth = 0.60 * flutter;
        let jitter_base = JITTER_BASE_MS * 0.001 * sr;
        let jitter_depth = (0.3 + 2.2 * jitter) * 0.001 * sr;

        let base_d = SHIFT_BASE_MS * 0.001 * sr;
        let grain_samples = GRAIN_MS * 0.001 * sr;
        let grain_rate = 1.0 / grain_samples;

        let shimmer_amt = 0.6 * shimmer;
        let bp_gain = (0.5 + 0.5 * bright) / 3.0;

        for f in 0..ctx.frames() {
            let t0 = TREM_LFO[0].tick();
            let t1 = TREM_LFO[1].tick();
            let t2 = TREM_LFO[2].tick();
            let walk = (t0 + t1 + t2) / 3.0;
            let trem_mod = (1.0 - trem_depth) + trem_depth * (0.5 + 0.5 * walk);

            let j = JITTER_LFO.tick();
            let mut jd = jitter_base + j * jitter_depth;
            if jd < 1.0 {
                jd = 1.0;
            }

            let ph0 = GRAIN_PHASE;
            let ph1 = (GRAIN_PHASE + 0.5) % 1.0;
            let w0_ = (core::f64::consts::PI * ph0).sin();
            let w0 = w0_ * w0_;
            let w1_ = (core::f64::consts::PI * ph1).sin();
            let w1 = w1_ * w1_;
            let mut read0 = base_d - ph0 * grain_samples;
            if read0 < 1.0 {
                read0 = 1.0;
            }
            let mut read1 = base_d - ph1 * grain_samples;
            if read1 < 1.0 {
                read1 = 1.0;
            }
            GRAIN_PHASE = (GRAIN_PHASE + grain_rate) % 1.0;

            for ch in 0..nch {
                let dry = ctx.input(ch, f) as f64;
                let dry_trem = dry * trem_mod;

                let mut bp_sum: f64 = 0.0;
                for k in 0..3 {
                    bp_sum += BP[ch][k].process_sample(dry_trem);
                }
                bp_sum *= bp_gain;

                JITTER_DL[ch].write(bp_sum as f32);
                let jittered = JITTER_DL[ch].read(jd) as f64;

                SHIFT_DL[ch].write(jittered as f32);
                let g0 = SHIFT_DL[ch].read(read0) as f64;
                let g1 = SHIFT_DL[ch].read(read1) as f64;
                let shimmer_voice = (w0 * g0 + w1 * g1) * shimmer_amt;

                let wet = jittered + shimmer_voice;
                ctx.set_output(ch, f, (dry * (1.0 - mx) + wet * mx) as f32);
            }
        }
    }
}
