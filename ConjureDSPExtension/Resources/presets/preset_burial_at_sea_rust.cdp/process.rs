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

persist_buf!(SHIFT_DL: [DelayLine<MAX_DL>; 2] = [DelayLine::new(); 2]);
persist_buf!(CLOSE_LP: [f64; 2] = [0.0; 2]);
persist_buf!(BELL_F: [Biquad; 2] = [Biquad::new(); 2]);
persist_buf!(SUB_LP: [Biquad; 2] = [Biquad::new(); 2]);
persist_buf!(TAIL_DL: [DelayLine<MAX_DL>; 2] = [DelayLine::new(); 2]);
persist_buf!(TAIL_LP: [Biquad; 2] = [Biquad::new(); 2]);
persist_buf!(TAIL_FB: [f64; 2] = [0.0; 2]);
persist!(GRAIN_PHASE: f64 = 0.0);

process! { ctx =>
    let sr = ctx.sample_rate() as f64;

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

    let base_d = SHIFT_BASE_MS * 0.001 * sr;
    let grain_samples = GRAIN_MS * 0.001 * sr;
    let grain_rate = (0.2 + 1.0 * descent) / grain_samples;

    let tail_d = TAIL_MS * 0.001 * sr;
    let tail_fb_amt = 0.55 + 0.30 * tail;

    let bell_gain = bell_amt * 0.6;
    let sub_gain: f64 = 1.2;

    let mut grain_phase = GRAIN_PHASE.get();

    SHIFT_DL.with_mut(|shift_dl| {
        CLOSE_LP.with_mut(|close_lp| {
            BELL_F.with_mut(|bell_f| {
                SUB_LP.with_mut(|sub_lp| {
                    TAIL_DL.with_mut(|tail_dl| {
                        TAIL_LP.with_mut(|tail_lp| {
                            TAIL_FB.with_mut(|tail_fb| {
                                for ch in 0..nch {
                                    bell_f[ch].set_coeffs(bell_c);
                                    sub_lp[ch].set_coeffs(sub_lpc);
                                    tail_lp[ch].set_coeffs(tail_lpc);
                                }

                                for f in 0..ctx.frames() {
                                    let ph0 = grain_phase;
                                    let ph1 = (grain_phase + 0.5) % 1.0;
                                    let w0_ = (core::f64::consts::PI * ph0).sin();
                                    let w0 = w0_ * w0_;
                                    let w1_ = (core::f64::consts::PI * ph1).sin();
                                    let w1 = w1_ * w1_;
                                    let read0 = base_d + ph0 * grain_samples;
                                    let read1 = base_d + ph1 * grain_samples;
                                    grain_phase = (grain_phase + grain_rate) % 1.0;

                                    for ch in 0..nch {
                                        let dry = ctx.input(ch, f) as f64;

                                        // Stage A: dual-tap downward pitch shifter
                                        shift_dl[ch].write(dry as f32);
                                        let g0 = shift_dl[ch].read(read0) as f64;
                                        let g1 = shift_dl[ch].read(read1) as f64;
                                        let shifted = w0 * g0 + w1 * g1;

                                        // Stage B: closing lowpass (depth-controlled descent)
                                        close_lp[ch] = close_alpha * close_lp[ch] + close_one_minus * shifted;
                                        let closed = close_lp[ch];

                                        // Stage C: distant bell resonator (peaking EQ on the closed bus)
                                        let bell_voice = bell_f[ch].process_sample(closed) * bell_gain;

                                        // Stage D: sub swell from rectified envelope
                                        let sub_voice = sub_lp[ch].process_sample(dry.abs()) * sub_gain;

                                        // Stage E: long dark feedback comb tail
                                        let tail_in = closed + bell_voice;
                                        let f_in = tail_lp[ch].process_sample(tail_fb[ch]);
                                        tail_dl[ch].write((tail_in + tail_fb_amt * f_in) as f32);
                                        tail_fb[ch] = tail_dl[ch].read(tail_d) as f64;

                                        // Final wet sum + mix
                                        let wet = closed + bell_voice + sub_voice + tail_fb[ch] * 0.5;
                                        ctx.set_output(ch, f, (dry * (1.0 - mx) + wet * mx) as f32);
                                    }
                                }
                            });
                        });
                    });
                });
            });
        });
    });

    GRAIN_PHASE.set(grain_phase);
}
