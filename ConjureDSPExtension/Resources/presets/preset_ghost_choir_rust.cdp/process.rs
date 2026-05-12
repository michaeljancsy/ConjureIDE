// Ghost Choir — choir of ghosts whispering secrets backwards.
//
// Lowpass formant softening → 3 series vowel-formant peak filters → 8-voice
// prime-spaced chorus modulated by 8 coprime LFOs → reversed-attack envelope
// shaper (slow-attack one-pole on delayed-dry abs) modulating chorus voices →
// whisper-band parallel layer → 4 modulated comb cathedral wash → 2 allpass
// diffusers → mid/side widening → breathing tremolo → mix.
//
// Params:
//   VOICES  (ms)  — chorus depth (0.5–6)
//   AIR     (Hz)  — formant softening LP cutoff (1500–6000)
//   WHISPER (pct) — whisper layer level
//   WASH    (pct) — cathedral wash level
//   MIX           — wet/dry blend

use conjuredsp::*;
params! {
    VOICES = time_ms().min(0.5).max(6.0).default(2.5),
    AIR = freq().min(1500.0).max(6000.0).default(3500.0),
    WHISPER = pct().default(45.0),
    WASH = pct().default(60.0),
    MIX = mix().default(0.6),
}

const MAX_DL: usize = 14400;

const CH_MS: [f64; 8] = [11.0, 13.0, 17.0, 19.0, 23.0, 29.0, 31.0, 37.0];
const CH_LFO_HZ: [f64; 8] = [0.21, 0.27, 0.33, 0.39, 0.45, 0.51, 0.57, 0.63];
const FORMANT_HZ: [f64; 3] = [700.0, 1200.0, 2500.0];
const FORMANT_GAIN: f64 = 4.0;
const FORMANT_Q: f64 = 4.0;
const REV_DELAY_MS: f64 = 80.0;
const COMB_MS: [f64; 4] = [119.0, 137.0, 163.0, 197.0];
const COMB_LFO_HZ: [f64; 4] = [0.07, 0.09, 0.11, 0.13];
const COMB_DEPTH_MS: f64 = 2.0;
const COMB_FB: f64 = 0.78;
const AP_MS: [f64; 2] = [18.3, 7.9];
const AP_G: f64 = 0.6;
const TREM_HZ: f64 = 6.0;

persist_buf!(LP: [Biquad; 2] = [Biquad::new(); 2]);
persist_buf!(FORMANTS: [[Biquad; 3]; 2] = [[Biquad::new(); 3]; 2]);
persist_buf!(CHORUS: [DelayLine<MAX_DL>; 2] = [DelayLine::new(); 2]);
persist_buf!(REV_DL: [DelayLine<MAX_DL>; 2] = [DelayLine::new(); 2]);
persist_buf!(REV_ENV: [f64; 2] = [0.0; 2]);
persist_buf!(WHISPER_BP: [Biquad; 2] = [Biquad::new(); 2]);
persist_buf!(WHISPER_HS: [Biquad; 2] = [Biquad::new(); 2]);
persist_buf!(COMBS: [[DelayLine<MAX_DL>; 4]; 2] = [[DelayLine::new(); 4]; 2]);
persist_buf!(COMB_FB_BUF: [[f64; 4]; 2] = [[0.0; 4]; 2]);
persist_buf!(COMB_LP: [[Biquad; 4]; 2] = [[Biquad::new(); 4]; 2]);
persist_buf!(AP: [[DelayLine<MAX_DL>; 2]; 2] = [[DelayLine::new(); 2]; 2]);
persist_buf!(APS: [[f64; 2]; 2] = [[0.0; 2]; 2]);
persist_buf!(LFO_CHORUS: [Lfo; 8] = [Lfo::new(); 8]);
persist_buf!(LFO_COMBS: [Lfo; 4] = [Lfo::new(); 4]);
persist_buf!(LFO_TREM: Lfo = Lfo::new());

process! { ctx =>
    let sr = ctx.sample_rate() as f64;

    let voices_ms = ctx.param(VOICES) as f64;
    let air_hz = ctx.param(AIR) as f64;
    let whisper = ctx.param(WHISPER) as f64 / 100.0;
    let wash = ctx.param(WASH) as f64 / 100.0;
    let mx = ctx.param(MIX) as f64;

    // Filter coefficients
    let lpc = BiquadCoeffs::lowpass(air_hz, 0.707, sr);
    let formant_c: [BiquadCoeffs; 3] = [
        BiquadCoeffs::peak(FORMANT_HZ[0], FORMANT_Q, FORMANT_GAIN, sr),
        BiquadCoeffs::peak(FORMANT_HZ[1], FORMANT_Q, FORMANT_GAIN, sr),
        BiquadCoeffs::peak(FORMANT_HZ[2], FORMANT_Q, FORMANT_GAIN, sr),
    ];
    let whisper_bpc = BiquadCoeffs::bandpass(2500.0, 4.0, sr);
    let whisper_hsc = BiquadCoeffs::highshelf(8000.0, 0.707, 6.0, sr);
    let comb_lpc = BiquadCoeffs::lowpass(3000.0, 0.707, sr);

    let nch = ctx.channels().min(2);

    // Delay times (samples)
    let ch_d: [f64; 8] = [
        CH_MS[0] * 0.001 * sr,
        CH_MS[1] * 0.001 * sr,
        CH_MS[2] * 0.001 * sr,
        CH_MS[3] * 0.001 * sr,
        CH_MS[4] * 0.001 * sr,
        CH_MS[5] * 0.001 * sr,
        CH_MS[6] * 0.001 * sr,
        CH_MS[7] * 0.001 * sr,
    ];
    let voice_depth = voices_ms * 0.001 * sr;
    let rev_d = (REV_DELAY_MS * 0.001 * sr).max(1.0);
    let comb_d: [f64; 4] = [
        COMB_MS[0] * 0.001 * sr,
        COMB_MS[1] * 0.001 * sr,
        COMB_MS[2] * 0.001 * sr,
        COMB_MS[3] * 0.001 * sr,
    ];
    let comb_depth = COMB_DEPTH_MS * 0.001 * sr;
    let ap_d: [f64; 2] = [
        (AP_MS[0] * 0.001 * sr).max(1.0),
        (AP_MS[1] * 0.001 * sr).max(1.0),
    ];

    // Reversed-attack one-pole (100 ms attack)
    let rev_alpha = (-1.0_f64 / (0.100 * sr)).exp();
    let one_minus_rev = 1.0 - rev_alpha;

    let trem_depth: f64 = 0.08;

    LP.with_mut(|lp| {
        FORMANTS.with_mut(|formants| {
            CHORUS.with_mut(|chorus| {
                REV_DL.with_mut(|rev_dl| {
                    REV_ENV.with_mut(|rev_env| {
                        WHISPER_BP.with_mut(|whisper_bp| {
                            WHISPER_HS.with_mut(|whisper_hs| {
                                COMBS.with_mut(|combs| {
                                    COMB_FB_BUF.with_mut(|comb_fb_buf| {
                                        COMB_LP.with_mut(|comb_lp| {
                                            AP.with_mut(|ap| {
                                                APS.with_mut(|aps| {
                                                    LFO_CHORUS.with_mut(|lfo_chorus| {
                                                        LFO_COMBS.with_mut(|lfo_combs| {
                                                            LFO_TREM.with_mut(|lfo_trem| {
                                                                // LFO init
                                                                for k in 0..8 {
                                                                    lfo_chorus[k].init(sr, CH_LFO_HZ[k]);
                                                                }
                                                                for k in 0..4 {
                                                                    lfo_combs[k].init(sr, COMB_LFO_HZ[k]);
                                                                }
                                                                lfo_trem.init(sr, TREM_HZ);
                                                                lfo_trem.set_waveform(Waveform::Triangle);

                                                                for ch in 0..nch {
                                                                    lp[ch].set_coeffs(lpc);
                                                                    for k in 0..3 {
                                                                        formants[ch][k].set_coeffs(formant_c[k]);
                                                                    }
                                                                    whisper_bp[ch].set_coeffs(whisper_bpc);
                                                                    whisper_hs[ch].set_coeffs(whisper_hsc);
                                                                    for k in 0..4 {
                                                                        comb_lp[ch][k].set_coeffs(comb_lpc);
                                                                    }
                                                                }

                                                                let mut wet: [f64; 2] = [0.0; 2];

                                                                for f in 0..ctx.frames() {
                                                                    let chl: [f64; 8] = [
                                                                        lfo_chorus[0].tick(),
                                                                        lfo_chorus[1].tick(),
                                                                        lfo_chorus[2].tick(),
                                                                        lfo_chorus[3].tick(),
                                                                        lfo_chorus[4].tick(),
                                                                        lfo_chorus[5].tick(),
                                                                        lfo_chorus[6].tick(),
                                                                        lfo_chorus[7].tick(),
                                                                    ];
                                                                    let cbl: [f64; 4] = [
                                                                        lfo_combs[0].tick(),
                                                                        lfo_combs[1].tick(),
                                                                        lfo_combs[2].tick(),
                                                                        lfo_combs[3].tick(),
                                                                    ];
                                                                    let trem = lfo_trem.tick();
                                                                    let trem_gain = 1.0 - trem_depth * (1.0 - (trem + 1.0) * 0.5);

                                                                    for ch in 0..nch {
                                                                        let dry = ctx.input(ch, f) as f64;

                                                                        // Stage A: lowpass formant softening
                                                                        let mut x = lp[ch].process_sample(dry);

                                                                        // Stage B: vowel formant peaks
                                                                        x = formants[ch][0].process_sample(x);
                                                                        x = formants[ch][1].process_sample(x);
                                                                        x = formants[ch][2].process_sample(x);

                                                                        // Stage C: 8-voice chorus
                                                                        chorus[ch].write(x as f32);
                                                                        let d0 = (ch_d[0] + chl[0] * voice_depth).max(1.0);
                                                                        let d1 = (ch_d[1] + chl[1] * voice_depth).max(1.0);
                                                                        let d2 = (ch_d[2] + chl[2] * voice_depth).max(1.0);
                                                                        let d3 = (ch_d[3] + chl[3] * voice_depth).max(1.0);
                                                                        let d4 = (ch_d[4] + chl[4] * voice_depth).max(1.0);
                                                                        let d5 = (ch_d[5] + chl[5] * voice_depth).max(1.0);
                                                                        let d6 = (ch_d[6] + chl[6] * voice_depth).max(1.0);
                                                                        let d7 = (ch_d[7] + chl[7] * voice_depth).max(1.0);
                                                                        let csum = (chorus[ch].read(d0) as f64
                                                                            + chorus[ch].read(d1) as f64
                                                                            + chorus[ch].read(d2) as f64
                                                                            + chorus[ch].read(d3) as f64
                                                                            + chorus[ch].read(d4) as f64
                                                                            + chorus[ch].read(d5) as f64
                                                                            + chorus[ch].read(d6) as f64
                                                                            + chorus[ch].read(d7) as f64)
                                                                            * 0.125;

                                                                        // Stage D: reversed-attack envelope shaper on delayed dry
                                                                        rev_dl[ch].write(dry as f32);
                                                                        let rev_tap = rev_dl[ch].read(rev_d) as f64;
                                                                        let target = rev_tap.abs();
                                                                        rev_env[ch] = rev_alpha * rev_env[ch] + one_minus_rev * target;
                                                                        let chorus_voice = csum * (0.4 + 1.6 * rev_env[ch]);

                                                                        // Stage E: whisper layer (parallel)
                                                                        let mut wb = whisper_bp[ch].process_sample(x);
                                                                        wb = (wb * 1.5).tanh();
                                                                        wb = whisper_hs[ch].process_sample(wb);
                                                                        let whisper_voice = wb * whisper;

                                                                        // Stage F: cathedral wash — 4 modulated comb filters
                                                                        let wash_in = chorus_voice;
                                                                        let cw0 = (comb_d[0] + cbl[0] * comb_depth).max(1.0);
                                                                        let cw1 = (comb_d[1] + cbl[1] * comb_depth).max(1.0);
                                                                        let cw2 = (comb_d[2] + cbl[2] * comb_depth).max(1.0);
                                                                        let cw3 = (comb_d[3] + cbl[3] * comb_depth).max(1.0);
                                                                        let f0 = comb_lp[ch][0].process_sample(comb_fb_buf[ch][0]);
                                                                        let f1 = comb_lp[ch][1].process_sample(comb_fb_buf[ch][1]);
                                                                        let f2 = comb_lp[ch][2].process_sample(comb_fb_buf[ch][2]);
                                                                        let f3 = comb_lp[ch][3].process_sample(comb_fb_buf[ch][3]);
                                                                        combs[ch][0].write((wash_in + COMB_FB * f0) as f32);
                                                                        combs[ch][1].write((wash_in + COMB_FB * f1) as f32);
                                                                        combs[ch][2].write((wash_in + COMB_FB * f2) as f32);
                                                                        combs[ch][3].write((wash_in + COMB_FB * f3) as f32);
                                                                        comb_fb_buf[ch][0] = combs[ch][0].read(cw0) as f64;
                                                                        comb_fb_buf[ch][1] = combs[ch][1].read(cw1) as f64;
                                                                        comb_fb_buf[ch][2] = combs[ch][2].read(cw2) as f64;
                                                                        comb_fb_buf[ch][3] = combs[ch][3].read(cw3) as f64;
                                                                        let cathedral = (comb_fb_buf[ch][0]
                                                                            + comb_fb_buf[ch][1]
                                                                            + comb_fb_buf[ch][2]
                                                                            + comb_fb_buf[ch][3])
                                                                            * 0.25;

                                                                        // Stage G: 2 cascaded Schroeder allpass diffusers
                                                                        let mut sig = chorus_voice + whisper_voice + cathedral * wash;
                                                                        for k in 0..2 {
                                                                            let vd = aps[ch][k];
                                                                            let vn = sig + AP_G * vd;
                                                                            ap[ch][k].write(vn as f32);
                                                                            aps[ch][k] = ap[ch][k].read(ap_d[k]) as f64;
                                                                            sig = vd - AP_G * vn;
                                                                        }

                                                                        wet[ch] = sig;
                                                                    }

                                                                    // Stage H: mid/side widening
                                                                    if nch >= 2 {
                                                                        let mid = (wet[0] + wet[1]) * 0.5;
                                                                        let side = (wet[0] - wet[1]) * 0.5 * 1.7;
                                                                        wet[0] = mid + side;
                                                                        wet[1] = mid - side;
                                                                    }

                                                                    // Stage I: breathing tremolo + final mix
                                                                    for ch in 0..nch {
                                                                        let dry = ctx.input(ch, f) as f64;
                                                                        ctx.set_output(ch, f, (dry * (1.0 - mx) + wet[ch] * trem_gain * mx) as f32);
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
                            });
                        });
                    });
                });
            });
        });
    });
}
