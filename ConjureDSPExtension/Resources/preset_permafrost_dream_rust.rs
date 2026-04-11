// Permafrost Dream — icy reverb breathing slowly under a frozen lake.
//
// Long feedback delay tail (290 ms) with octave-up pitch shift in the
// feedback path (true shimmer architecture: tail → LP → dual-tap shifter →
// back into delay input) → glassy 3-bandpass cluster (2.5 / 3.7 / 5.1 kHz)
// whose amplitude is modulated by a slow 0.09 Hz "breath" LFO → high-pass
// (400 Hz) to keep the wet bus bright → final mix.
//
// Distinct from Haunted Cathedral: bright/shimmer reverb rather than dark
// dense; first preset where the pitch shifter lives inside the reverb
// feedback loop.
//
// Params:
//   ICE     (pct) — tail feedback (length of shimmer)
//   SHIMMER (pct) — how much pitch-shifted content re-enters the tail
//   GLASS   (pct) — bandpass cluster gain
//   BREATH  (pct) — slow LFO depth on the glass layer
//   MIX           — wet/dry blend

use conjuredsp::*;
setup!();

params! {
    ICE = pct().default(70.0),
    SHIMMER = pct().default(55.0),
    GLASS = pct().default(50.0),
    BREATH = pct().default(60.0),
    MIX = mix().default(0.55),
}

const MAX_DL: usize = 50000;

const TAIL_MS: f64 = 290.0;
const SHIFT_BASE_MS: f64 = 60.0;
const GRAIN_MS: f64 = 80.0;
const BP_HZ: [f64; 3] = [2500.0, 3700.0, 5100.0];
const BREATH_HZ: f64 = 0.09;

static mut TAIL_DL: [DelayLine<MAX_DL>; 2] = [DelayLine::new(); 2];
static mut TAIL_LP: [Biquad; 2] = [Biquad::new(); 2];
static mut SHIFT_DL: [DelayLine<MAX_DL>; 2] = [DelayLine::new(); 2];
static mut GLASS_BP: [[Biquad; 3]; 2] = [[Biquad::new(); 3]; 2];
static mut HP: [Biquad; 2] = [Biquad::new(); 2];
static mut GRAIN_PHASE: f64 = 0.0;
static mut BREATH_LFO: Lfo = Lfo::new();

#[no_mangle]
pub extern "C" fn process(
    input: *const f32, output: *mut f32,
    channels: i32, frame_count: i32, sample_rate: f32,
) {
    let ctx = ctx(input, output, channels, frame_count, sample_rate);
    let sr = ctx.sample_rate() as f64;

    unsafe {
        let ice = ctx.param(ICE) as f64 / 100.0;
        let shimmer = ctx.param(SHIMMER) as f64 / 100.0;
        let glass = ctx.param(GLASS) as f64 / 100.0;
        let breath = ctx.param(BREATH) as f64 / 100.0;
        let mx = ctx.param(MIX) as f64;

        let glass_q = 6.0 + 6.0 * glass;
        let tail_lpc = BiquadCoeffs::lowpass(2800.0, 0.707, sr);
        let bp_c: [BiquadCoeffs; 3] = [
            BiquadCoeffs::bandpass(BP_HZ[0], glass_q, sr),
            BiquadCoeffs::bandpass(BP_HZ[1], glass_q, sr),
            BiquadCoeffs::bandpass(BP_HZ[2], glass_q, sr),
        ];
        let hpc = BiquadCoeffs::highpass(400.0, 0.707, sr);

        BREATH_LFO.init(sr, BREATH_HZ);

        let nch = ctx.channels().min(2);
        for ch in 0..nch {
            TAIL_LP[ch].set_coeffs(tail_lpc);
            for k in 0..3 {
                GLASS_BP[ch][k].set_coeffs(bp_c[k]);
            }
            HP[ch].set_coeffs(hpc);
        }

        let tail_d = TAIL_MS * 0.001 * sr;
        let tail_fb_amt = 0.55 + 0.30 * ice;
        let shimmer_amt = 0.70 * shimmer;

        let base_d = SHIFT_BASE_MS * 0.001 * sr;
        let grain_samples = GRAIN_MS * 0.001 * sr;
        let grain_rate = 1.0 / grain_samples;

        let glass_gain = 0.30 + 0.70 * glass;
        let breath_depth = 0.40 * breath;

        for f in 0..ctx.frames() {
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

            let b = BREATH_LFO.tick();
            let breath_mod = 1.0 - breath_depth + breath_depth * (0.5 + 0.5 * b);

            for ch in 0..nch {
                let dry = ctx.input(ch, f) as f64;

                // Stage A: read tail, LP, pitch-shift inside feedback loop
                let tail_raw = TAIL_DL[ch].read(tail_d) as f64;
                let tail_lp_out = TAIL_LP[ch].process_sample(tail_raw);

                SHIFT_DL[ch].write(tail_lp_out as f32);
                let g0 = SHIFT_DL[ch].read(read0) as f64;
                let g1 = SHIFT_DL[ch].read(read1) as f64;
                let shifted = w0 * g0 + w1 * g1;

                // Stage B: feedback composition (dry + shimmer + LP'd tail)
                let fb_in = dry + shifted * shimmer_amt + tail_lp_out * tail_fb_amt;
                TAIL_DL[ch].write(fb_in as f32);

                // Stage C: glassy bandpass cluster on raw tail
                let mut glass_sum: f64 = 0.0;
                for k in 0..3 {
                    glass_sum += GLASS_BP[ch][k].process_sample(tail_raw);
                }
                let glass_voice = glass_sum * glass_gain * breath_mod;

                // Stage D: high-pass
                let wet = HP[ch].process_sample(tail_raw + glass_voice);

                ctx.set_output(ch, f, (dry * (1.0 - mx) + wet * mx) as f32);
            }
        }
    }
}
