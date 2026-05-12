// Morphine Drip — narcotic haze, time slowing between heartbeats.
//
// Slow 0.5 Hz "drip" envelope (triangle LFO squared → sin²-like pulsing) as
// the primary amplitude gate → narcotic slow pitch drift (single dual-tap
// delay modulated by a 0.23 Hz sine LFO) → soft tanh saturation → long
// lowpass-feedback delay (380 ms, dark feedback path) → final mix.
//
// Distinct from Broken Fax Lullaby: single slow drip instead of coprime
// square-gate chorus; narcotic mood vs broken-fax mechanical clatter. The
// drip envelope IS the sound rather than a side stage.
//
// Params:
//   DRIP  (pct) — drip envelope depth
//   HAZE  (pct) — tanh saturation drive
//   DRIFT (pct) — slow pitch drift depth
//   BLEED (pct) — feedback delay amount
//   MIX         — wet/dry blend

use conjuredsp::*;
params! {
    DRIP = pct().default(70.0),
    HAZE = pct().default(50.0),
    DRIFT = pct().default(45.0),
    BLEED = pct().default(60.0),
    MIX = mix().default(0.55),
}

const MAX_DL: usize = 60000;

const DRIP_HZ: f64 = 0.5;
const DRIFT_HZ: f64 = 0.23;
const DELAY_MS: f64 = 380.0;
const DRIFT_BASE_MS: f64 = 15.0;

persist_buf!(DRIP_LFO: Lfo = Lfo::new());
persist_buf!(DRIFT_LFO: Lfo = Lfo::new());
persist_buf!(DRIFT_DL: [DelayLine<MAX_DL>; 2] = [DelayLine::new(); 2]);
persist_buf!(DELAY_DL: [DelayLine<MAX_DL>; 2] = [DelayLine::new(); 2]);
persist_buf!(DELAY_LP: [Biquad; 2] = [Biquad::new(); 2]);
persist_buf!(DELAY_FB: [f64; 2] = [0.0; 2]);

process! { ctx =>
    let sr = ctx.sample_rate() as f64;

    let drip = ctx.param(DRIP) as f64 / 100.0;
    let haze = ctx.param(HAZE) as f64 / 100.0;
    let drift = ctx.param(DRIFT) as f64 / 100.0;
    let bleed = ctx.param(BLEED) as f64 / 100.0;
    let mx = ctx.param(MIX) as f64;

    let delay_lpc = BiquadCoeffs::lowpass(1200.0, 0.707, sr);
    let nch = ctx.channels().min(2);

    let drip_depth = 0.85 * drip;
    let drive = 1.0 + 4.0 * haze;
    let drift_base = DRIFT_BASE_MS * 0.001 * sr;
    let drift_depth = (2.0 + 8.0 * drift) * 0.001 * sr;
    let delay_d = DELAY_MS * 0.001 * sr;
    let delay_fb_amt = 0.55 + 0.30 * bleed;

    DRIP_LFO.with_mut(|drip_lfo| {
        DRIFT_LFO.with_mut(|drift_lfo| {
            DRIFT_DL.with_mut(|drift_dl| {
                DELAY_DL.with_mut(|delay_dl| {
                    DELAY_LP.with_mut(|delay_lp| {
                        DELAY_FB.with_mut(|delay_fb| {
                            drip_lfo.init(sr, DRIP_HZ);
                            drip_lfo.set_waveform(Waveform::Triangle);
                            drift_lfo.init(sr, DRIFT_HZ);

                            for ch in 0..nch {
                                delay_lp[ch].set_coeffs(delay_lpc);
                            }

                            for f in 0..ctx.frames() {
                                let tri = drip_lfo.tick();
                                let pulse = 0.5 + 0.5 * tri;
                                let drip_env = (1.0 - drip_depth) + drip_depth * pulse * pulse;

                                let drift_val = drift_lfo.tick();
                                let mut dd = drift_base + drift_val * drift_depth;
                                if dd < 1.0 {
                                    dd = 1.0;
                                }

                                for ch in 0..nch {
                                    let dry = ctx.input(ch, f) as f64;

                                    let gated = dry * drip_env;

                                    drift_dl[ch].write(gated as f32);
                                    let drifted = drift_dl[ch].read(dd) as f64;

                                    let sat = (drifted * drive).tanh() / drive;

                                    let f_in = delay_lp[ch].process_sample(delay_fb[ch]);
                                    delay_dl[ch].write((sat + delay_fb_amt * f_in) as f32);
                                    delay_fb[ch] = delay_dl[ch].read(delay_d) as f64;

                                    let wet = sat + delay_fb[ch] * 0.7;
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
