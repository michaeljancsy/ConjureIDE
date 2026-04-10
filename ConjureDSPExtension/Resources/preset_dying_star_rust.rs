// Dying Star — kick → dying star collapsing into a black hole.
//
// Sub-bass rumble bus (rectify → 80 Hz LP) → gravitational redshift dual-tap
// pitch shifter → 4 cascaded Schroeder allpass diffusers (dispersion lensing)
// → closing one-pole lowpass (collapse-controlled cutoff) → Schwarzschild
// resonance bandpass at 110 Hz → event-horizon bit reduction → final mix.
//
// Params:
//   COLLAPSE (pct) — closes lowpass cutoff + drives bit reduction
//   GRAVITY  (pct) — pitch-shift drift rate
//   SUB      (pct) — rumble bus level
//   MIX            — wet/dry blend

use conjuredsp::*;
setup!();

params! {
    COLLAPSE = pct().default(55.0),
    GRAVITY = pct().default(60.0),
    SUB = pct().default(70.0),
    MIX = mix().default(0.6),
}

const MAX_DL: usize = 24000;

const SHIFT_BASE_MS: f64 = 50.0;
const GRAIN_MS: f64 = 80.0;
const AP_MS: [f64; 4] = [11.3, 17.7, 23.1, 29.9];
const AP_G: f64 = 0.65;

static mut SUB_LP: [Biquad; 2] = [Biquad::new(); 2];
static mut SHIFT_DL: [DelayLine<MAX_DL>; 2] = [DelayLine::new(); 2];
static mut AP: [[DelayLine<MAX_DL>; 4]; 2] = [[DelayLine::new(); 4]; 2];
static mut APS: [[f64; 4]; 2] = [[0.0; 4]; 2];
static mut CLOSE_LP: [f64; 2] = [0.0; 2];
static mut RING: [Biquad; 2] = [Biquad::new(); 2];
static mut GRAIN_PHASE: f64 = 0.0;

#[no_mangle]
pub extern "C" fn process(
    input: *const f32, output: *mut f32,
    channels: i32, frame_count: i32, sample_rate: f32,
) {
    let ctx = ctx(input, output, channels, frame_count, sample_rate);
    let sr = ctx.sample_rate() as f64;

    unsafe {
        let collapse = ctx.param(COLLAPSE) as f64 / 100.0;
        let gravity = ctx.param(GRAVITY) as f64 / 100.0;
        let sub = ctx.param(SUB) as f64 / 100.0;
        let mx = ctx.param(MIX) as f64;

        // Sub-bass lowpass coefficients (80 Hz Q=0.7)
        let sub_lpc = BiquadCoeffs::lowpass(80.0, 0.707, sr);
        // Schwarzschild ringing bandpass at 110 Hz, Q=18
        let ringc = BiquadCoeffs::bandpass(110.0, 18.0, sr);
        let nch = ctx.channels().min(2);
        for ch in 0..nch {
            SUB_LP[ch].set_coeffs(sub_lpc);
            RING[ch].set_coeffs(ringc);
        }

        // Closing lowpass: cutoff sweeps from 8000 Hz (collapse=0) to 350 Hz (collapse=1)
        let close_fc = 8000.0 - 7650.0 * collapse;
        let close_alpha = (-2.0 * core::f64::consts::PI * close_fc / sr).exp();
        let close_one_minus = 1.0 - close_alpha;

        // Pitch shifter
        let base_d = SHIFT_BASE_MS * 0.001 * sr;
        let grain_samples = GRAIN_MS * 0.001 * sr;
        let grain_rate = (0.4 + 1.6 * gravity) / grain_samples;

        // Bit reduction: 8 bits at collapse=0, 2 bits at collapse=1
        let bits = 8.0 - 6.0 * collapse;
        let levels = (2.0_f64).powf(bits);
        let inv_levels = 1.0 / levels;

        // Allpass times in samples
        let ap_d: [f64; 4] = [
            (AP_MS[0] * 0.001 * sr).max(1.0),
            (AP_MS[1] * 0.001 * sr).max(1.0),
            (AP_MS[2] * 0.001 * sr).max(1.0),
            (AP_MS[3] * 0.001 * sr).max(1.0),
        ];

        let rumble_gain = sub * 1.5;
        let ring_gain: f64 = 0.4;

        for f in 0..ctx.frames() {
            let ph0 = GRAIN_PHASE;
            let ph1 = (GRAIN_PHASE + 0.5) % 1.0;
            let w0_ = (core::f64::consts::PI * ph0).sin();
            let w0 = w0_ * w0_;
            let w1_ = (core::f64::consts::PI * ph1).sin();
            let w1 = w1_ * w1_;
            let read0 = base_d + ph0 * grain_samples;
            let read1 = base_d + ph1 * grain_samples;
            GRAIN_PHASE = (GRAIN_PHASE + grain_rate) % 1.0;

            for ch in 0..nch {
                let dry = ctx.input(ch, f) as f64;

                // Stage A: sub-bass rumble bus (rectify → LP → gain)
                let rectified = dry.abs();
                let rumble = SUB_LP[ch].process_sample(rectified) * rumble_gain;

                // Stage B: gravitational redshift pitch shift (dual-tap crossfade)
                SHIFT_DL[ch].write(dry as f32);
                let g0 = SHIFT_DL[ch].read(read0) as f64;
                let g1 = SHIFT_DL[ch].read(read1) as f64;
                let shifted = w0 * g0 + w1 * g1;

                // Stage C: 4 cascaded Schroeder allpass diffusers (lensing)
                let mut sig = shifted;
                for k in 0..4 {
                    let vd = APS[ch][k];
                    let vn = sig + AP_G * vd;
                    AP[ch][k].write(vn as f32);
                    APS[ch][k] = AP[ch][k].read(ap_d[k]) as f64;
                    sig = vd - AP_G * vn;
                }

                // Stage D: closing one-pole lowpass
                CLOSE_LP[ch] = close_alpha * CLOSE_LP[ch] + close_one_minus * sig;
                let closed = CLOSE_LP[ch];

                // Stage E: Schwarzschild resonance bandpass (parallel)
                let ringing = RING[ch].process_sample(closed) * ring_gain;

                // Stage F: event-horizon bit reduction on the closed bus
                let crushed = (closed * levels + 0.5).floor() * inv_levels;

                // Stage G: final wet sum + mix
                let wet = rumble + crushed + ringing;
                ctx.set_output(ch, f, (dry * (1.0 - mx) + wet * mx) as f32);
            }
        }
    }
}
