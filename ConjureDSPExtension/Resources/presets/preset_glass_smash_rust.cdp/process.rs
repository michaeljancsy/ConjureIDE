// Glass Smash — snare → glass bottle smashing in slow motion.
//
// 6-partial modal resonator bank (inharmonic glass frequencies with high-Q
// bandpass biquads) → octave-up crystalline shimmer (dual-tap pitch shifter)
// → granular slow-motion freezer (dual-tap pitch shifter, octave down) →
// sub-octave impact thud (rectify → 80 Hz LP) → 4 parallel feedback comb
// reverb tail (LP in feedback) → final mix.
//
// Params:
//   SHIMMER  (pct) — octave-up shimmer level
//   TIME     (pct) — reverb tail feedback
//   PARTIALS (pct) — modal resonator Q (12 → 35)
//   SLOWMO   (pct) — granular freezer level
//   MIX            — wet/dry blend

use conjuredsp::*;
params! {
    SHIMMER = pct().default(55.0),
    TIME = pct().default(60.0),
    PARTIALS = pct().default(50.0),
    SLOWMO = pct().default(40.0),
    MIX = mix().default(0.55),
}

const MAX_DL: usize = 24000;

const PARTIAL_HZ: [f64; 6] = [2700.0, 3850.0, 5100.0, 6700.0, 8400.0, 11200.0];
const SHIMMER_BASE_MS: f64 = 60.0;
const SHIMMER_GRAIN_MS: f64 = 60.0;
const GRAN_BASE_MS: f64 = 80.0;
const GRAN_GRAIN_MS: f64 = 100.0;
const COMB_MS: [f64; 4] = [200.0, 250.0, 310.0, 370.0];

persist_mut!(MODAL: [[Biquad; 6]; 2] = [[Biquad::new(); 6]; 2]);
persist_mut!(SHIMMER_DL: [DelayLine<MAX_DL>; 2] = [DelayLine::new(); 2]);
persist_mut!(GRAN_DL: [DelayLine<MAX_DL>; 2] = [DelayLine::new(); 2]);
persist_mut!(SUB_LP: [Biquad; 2] = [Biquad::new(); 2]);
persist_mut!(SHIM_HP: [Biquad; 2] = [Biquad::new(); 2]);
persist_mut!(COMBS: [[DelayLine<MAX_DL>; 4]; 2] = [[DelayLine::new(); 4]; 2]);
persist_mut!(COMB_FB_BUF: [[f64; 4]; 2] = [[0.0; 4]; 2]);
persist_mut!(COMB_LP: [[Biquad; 4]; 2] = [[Biquad::new(); 4]; 2]);
persist!(SHIM_PHASE: f64 = 0.0);
persist!(GRAN_PHASE: f64 = 0.0);

process! { ctx =>
    let sr = ctx.sample_rate() as f64;

    let shimmer = ctx.param(SHIMMER) as f64 / 100.0;
    let time_p = ctx.param(TIME) as f64 / 100.0;
    let partials = ctx.param(PARTIALS) as f64 / 100.0;
    let slowmo = ctx.param(SLOWMO) as f64 / 100.0;
    let mx = ctx.param(MIX) as f64;

    // Modal Q ranges from 12 (low partials) to 35 (high partials)
    let modal_q = 12.0 + 23.0 * partials;
    let modal_c: [BiquadCoeffs; 6] = [
        BiquadCoeffs::bandpass(PARTIAL_HZ[0], modal_q, sr),
        BiquadCoeffs::bandpass(PARTIAL_HZ[1], modal_q, sr),
        BiquadCoeffs::bandpass(PARTIAL_HZ[2], modal_q, sr),
        BiquadCoeffs::bandpass(PARTIAL_HZ[3], modal_q, sr),
        BiquadCoeffs::bandpass(PARTIAL_HZ[4], modal_q, sr),
        BiquadCoeffs::bandpass(PARTIAL_HZ[5], modal_q, sr),
    ];
    let sub_lpc = BiquadCoeffs::lowpass(80.0, 0.707, sr);
    let shim_hpc = BiquadCoeffs::highpass(800.0, 0.707, sr);
    let comb_lpc = BiquadCoeffs::lowpass(4000.0, 0.707, sr);
    let nch = ctx.channels().min(2);

    // Pitch shifter delay parameters (samples)
    let shim_base = SHIMMER_BASE_MS * 0.001 * sr;
    let shim_grain = SHIMMER_GRAIN_MS * 0.001 * sr;
    let gran_base = GRAN_BASE_MS * 0.001 * sr;
    let gran_grain = GRAN_GRAIN_MS * 0.001 * sr;

    let shim_rate = 1.0 / shim_grain;
    let gran_rate = 0.5 / gran_grain;

    let comb_d: [f64; 4] = [
        COMB_MS[0] * 0.001 * sr,
        COMB_MS[1] * 0.001 * sr,
        COMB_MS[2] * 0.001 * sr,
        COMB_MS[3] * 0.001 * sr,
    ];
    let comb_fb_amt = 0.55 + 0.30 * time_p;

    let modal_gain: f64 = 2.0;
    let sub_gain: f64 = 0.8;

    let mut shim_phase = SHIM_PHASE.get();
    let mut gran_phase = GRAN_PHASE.get();

    MODAL.with_mut(|modal| {
        SHIMMER_DL.with_mut(|shimmer_dl| {
            GRAN_DL.with_mut(|gran_dl| {
                SUB_LP.with_mut(|sub_lp| {
                    SHIM_HP.with_mut(|shim_hp| {
                        COMBS.with_mut(|combs| {
                            COMB_FB_BUF.with_mut(|comb_fb_buf| {
                                COMB_LP.with_mut(|comb_lp| {
                                    for ch in 0..nch {
                                        for k in 0..6 {
                                            modal[ch][k].set_coeffs(modal_c[k]);
                                        }
                                        sub_lp[ch].set_coeffs(sub_lpc);
                                        shim_hp[ch].set_coeffs(shim_hpc);
                                        for k in 0..4 {
                                            comb_lp[ch][k].set_coeffs(comb_lpc);
                                        }
                                    }

                                    for f in 0..ctx.frames() {
                                        let sh_ph0 = shim_phase;
                                        let sh_ph1 = (shim_phase + 0.5) % 1.0;
                                        let sh_w0_ = (core::f64::consts::PI * sh_ph0).sin();
                                        let sh_w0 = sh_w0_ * sh_w0_;
                                        let sh_w1_ = (core::f64::consts::PI * sh_ph1).sin();
                                        let sh_w1 = sh_w1_ * sh_w1_;
                                        let mut sh_read0 = shim_base - sh_ph0 * shim_grain;
                                        let mut sh_read1 = shim_base - sh_ph1 * shim_grain;
                                        if sh_read0 < 1.0 {
                                            sh_read0 = 1.0;
                                        }
                                        if sh_read1 < 1.0 {
                                            sh_read1 = 1.0;
                                        }
                                        shim_phase = (shim_phase + shim_rate) % 1.0;

                                        let gr_ph0 = gran_phase;
                                        let gr_ph1 = (gran_phase + 0.5) % 1.0;
                                        let gr_w0_ = (core::f64::consts::PI * gr_ph0).sin();
                                        let gr_w0 = gr_w0_ * gr_w0_;
                                        let gr_w1_ = (core::f64::consts::PI * gr_ph1).sin();
                                        let gr_w1 = gr_w1_ * gr_w1_;
                                        let gr_read0 = gran_base + gr_ph0 * gran_grain;
                                        let gr_read1 = gran_base + gr_ph1 * gran_grain;
                                        gran_phase = (gran_phase + gran_rate) % 1.0;

                                        for ch in 0..nch {
                                            let dry = ctx.input(ch, f) as f64;

                                            // Stage A: modal resonator bank (6 parallel high-Q bandpasses)
                                            let m0 = modal[ch][0].process_sample(dry);
                                            let m1 = modal[ch][1].process_sample(dry);
                                            let m2 = modal[ch][2].process_sample(dry);
                                            let m3 = modal[ch][3].process_sample(dry);
                                            let m4 = modal[ch][4].process_sample(dry);
                                            let m5 = modal[ch][5].process_sample(dry);
                                            let modal_sum = (m0 + m1 + m2 + m3 + m4 + m5) * modal_gain;

                                            // Stage B: octave-up crystalline shimmer (dual-tap pitch shifter)
                                            shimmer_dl[ch].write(modal_sum as f32);
                                            let sg0 = shimmer_dl[ch].read(sh_read0) as f64;
                                            let sg1 = shimmer_dl[ch].read(sh_read1) as f64;
                                            let mut shim_voice = (sh_w0 * sg0 + sh_w1 * sg1) * shimmer;
                                            shim_voice = shim_hp[ch].process_sample(shim_voice);

                                            // Stage C: granular slow-motion (octave down, dual-tap shifter)
                                            gran_dl[ch].write(modal_sum as f32);
                                            let ng0 = gran_dl[ch].read(gr_read0) as f64;
                                            let ng1 = gran_dl[ch].read(gr_read1) as f64;
                                            let gran_voice = (gr_w0 * ng0 + gr_w1 * ng1) * slowmo;

                                            // Stage D: sub-octave impact thud (rectify → LP → gain)
                                            let sub_voice = sub_lp[ch].process_sample(dry.abs()) * sub_gain;

                                            // Stage E: 4-comb reverb tail
                                            let comb_in = modal_sum + shim_voice + gran_voice;
                                            let f0 = comb_lp[ch][0].process_sample(comb_fb_buf[ch][0]);
                                            let f1 = comb_lp[ch][1].process_sample(comb_fb_buf[ch][1]);
                                            let f2 = comb_lp[ch][2].process_sample(comb_fb_buf[ch][2]);
                                            let f3 = comb_lp[ch][3].process_sample(comb_fb_buf[ch][3]);
                                            combs[ch][0].write((comb_in + comb_fb_amt * f0) as f32);
                                            combs[ch][1].write((comb_in + comb_fb_amt * f1) as f32);
                                            combs[ch][2].write((comb_in + comb_fb_amt * f2) as f32);
                                            combs[ch][3].write((comb_in + comb_fb_amt * f3) as f32);
                                            comb_fb_buf[ch][0] = combs[ch][0].read(comb_d[0]) as f64;
                                            comb_fb_buf[ch][1] = combs[ch][1].read(comb_d[1]) as f64;
                                            comb_fb_buf[ch][2] = combs[ch][2].read(comb_d[2]) as f64;
                                            comb_fb_buf[ch][3] = combs[ch][3].read(comb_d[3]) as f64;
                                            let tail = (comb_fb_buf[ch][0]
                                                + comb_fb_buf[ch][1]
                                                + comb_fb_buf[ch][2]
                                                + comb_fb_buf[ch][3])
                                                * 0.25;

                                            // Stage F: final wet sum + mix
                                            let wet = soft_clip(
                                                modal_sum + shim_voice + gran_voice + sub_voice + tail,
                                                1.0,
                                            );
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
    });

    SHIM_PHASE.set(shim_phase);
    GRAN_PHASE.set(gran_phase);
}
