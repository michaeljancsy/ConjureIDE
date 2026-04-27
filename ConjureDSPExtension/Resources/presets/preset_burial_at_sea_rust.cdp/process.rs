// Burial at Sea — a slow descent into deep water, a single bell tolling above.
//
// Slow continuous downward pitch droop (dual-tap pitch shifter, no bit-crush)
// → closing one-pole lowpass (depth-controlled, sweeping from 6 kHz to 400 Hz)
// → distant high-Q bell resonator (peaking EQ at 880 Hz) → sub swell from
// rectified envelope → long dark feedback comb tail → final mix.
//
// Distinct from Dying Star: this is the gentle funereal cousin — pure pitch
// collapse without the bit-reduction harshness, with a tolling bell instead
// of Schwarzschild ringing.
//
// Params:
//   DEPTH   (pct) — closes the lowpass and deepens the descent
//   DESCENT (pct) — pitch droop rate
//   BELL    (pct) — bell resonator level
//   TAIL    (pct) — long comb reverb feedback
//   MIX           — wet/dry blend

use conjuredsp::*;
setup!();

params! {
    DEPTH = pct().default(60.0),
    DESCENT = pct().default(50.0),
    BELL = pct().default(55.0),
    TAIL = pct().default(70.0),
    MIX = mix().default(0.55),
}

const MAX_DL: usize = 60000;

const SHIFT_BASE_MS: f64 = 60.0;
const GRAIN_MS: f64 = 100.0;
const BELL_HZ: f64 = 880.0;
const TAIL_MS: f64 = 420.0;

static mut SHIFT_DL: [DelayLine<MAX_DL>; 2] = [DelayLine::new(); 2];
static mut CLOSE_LP: [f64; 2] = [0.0; 2];
static mut BELL_F: [Biquad; 2] = [Biquad::new(); 2];
static mut SUB_LP: [Biquad; 2] = [Biquad::new(); 2];
static mut TAIL_DL: [DelayLine<MAX_DL>; 2] = [DelayLine::new(); 2];
static mut TAIL_LP: [Biquad; 2] = [Biquad::new(); 2];
static mut TAIL_FB: [f64; 2] = [0.0; 2];
static mut GRAIN_PHASE: f64 = 0.0;

#[no_mangle]
pub extern "C" fn process(
    input: *const f32, output: *mut f32,
    channel_count: i32, frame_count: i32, sample_rate: f32,
) {
    let ctx = ctx(input, output, channel_count, frame_count, sample_rate);
    let sr = ctx.sample_rate() as f64;

    unsafe {
        let depth = ctx.param(DEPTH) as f64 / 100.0;
        let descent = ctx.param(DESCENT) as f64 / 100.0;
        let bell_amt = ctx.param(BELL) as f64 / 100.0;
        let tail = ctx.param(TAIL) as f64 / 100.0;
        let mx = ctx.param(MIX) as f64;

        let close_fc = 6000.0 - 5600.0 * depth;
        let close_alpha = (-2.0 * core::f64::consts::PI * close_fc / sr).exp();
        let close_one_minus = 1.0 - close_alpha;

        let bell_c = BiquadCoeffs::peak(BELL_HZ, 12.0, 12.0, sr);
        let sub_lpc = BiquadCoeffs::lowpass(70.0, 0.707, sr);
        let tail_lpc = BiquadCoeffs::lowpass(1500.0, 0.707, sr);
        let nch = ctx.channels().min(2);
        for ch in 0..nch {
            BELL_F[ch].set_coeffs(bell_c);
            SUB_LP[ch].set_coeffs(sub_lpc);
            TAIL_LP[ch].set_coeffs(tail_lpc);
        }

        let base_d = SHIFT_BASE_MS * 0.001 * sr;
        let grain_samples = GRAIN_MS * 0.001 * sr;
        let grain_rate = (0.2 + 1.0 * descent) / grain_samples;

        let tail_d = TAIL_MS * 0.001 * sr;
        let tail_fb_amt = 0.55 + 0.30 * tail;

        let bell_gain = bell_amt * 0.6;
        let sub_gain: f64 = 1.2;

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

                // Stage A: dual-tap downward pitch shifter
                SHIFT_DL[ch].write(dry as f32);
                let g0 = SHIFT_DL[ch].read(read0) as f64;
                let g1 = SHIFT_DL[ch].read(read1) as f64;
                let shifted = w0 * g0 + w1 * g1;

                // Stage B: closing lowpass (depth-controlled descent)
                CLOSE_LP[ch] = close_alpha * CLOSE_LP[ch] + close_one_minus * shifted;
                let closed = CLOSE_LP[ch];

                // Stage C: distant bell resonator (peaking EQ on the closed bus)
                let bell_voice = BELL_F[ch].process_sample(closed) * bell_gain;

                // Stage D: sub swell from rectified envelope
                let sub_voice = SUB_LP[ch].process_sample(dry.abs()) * sub_gain;

                // Stage E: long dark feedback comb tail
                let tail_in = closed + bell_voice;
                let f_in = TAIL_LP[ch].process_sample(TAIL_FB[ch]);
                TAIL_DL[ch].write((tail_in + tail_fb_amt * f_in) as f32);
                TAIL_FB[ch] = TAIL_DL[ch].read(tail_d) as f64;

                // Final wet sum + mix
                let wet = closed + bell_voice + sub_voice + TAIL_FB[ch] * 0.5;
                ctx.set_output(ch, f, (dry * (1.0 - mx) + wet * mx) as f32);
            }
        }
    }
}
