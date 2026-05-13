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

// Whisper / voice chain: lowpass formant softening, 3 vowel formants,
// whisper-band BP + HS, breathing tremolo LFO.
struct Voice {
    lp: [Biquad; 2],
    formants: [[Biquad; 3]; 2],
    whisper_bp: [Biquad; 2],
    whisper_hs: [Biquad; 2],
    lfo_trem: Lfo,
}

// 8-voice prime-spaced chorus + 8 coprime modulation LFOs.
struct Chorus {
    dl: [DelayLine<MAX_DL>; 2],
    lfo: [Lfo; 8],
}

// 4-comb cathedral wash (with LP-in-feedback) + 2 Schroeder allpass
// diffusers + 4 comb-modulation LFOs.
struct Combs {
    dl: [[DelayLine<MAX_DL>; 4]; 2],
    fb_buf: [[f64; 4]; 2],
    lp: [[Biquad; 4]; 2],
    ap: [[DelayLine<MAX_DL>; 2]; 2],
    aps: [[f64; 2]; 2],
    lfo: [Lfo; 4],
}

// Reversed-attack envelope shaper on delayed dry.
struct Reverb {
    dl: [DelayLine<MAX_DL>; 2],
    env: [f64; 2],
}

persist_mut!(VOICE: Voice = Voice {
    lp: [const { Biquad::new() }; 2],
    formants: [const { [const { Biquad::new() }; 3] }; 2],
    whisper_bp: [const { Biquad::new() }; 2],
    whisper_hs: [const { Biquad::new() }; 2],
    lfo_trem: Lfo::new(),
});
persist_mut!(CHORUS: Chorus = Chorus {
    dl: [const { DelayLine::new() }; 2],
    lfo: [const { Lfo::new() }; 8],
});
persist_mut!(COMBS: Combs = Combs {
    dl: [const { [const { DelayLine::new() }; 4] }; 2],
    fb_buf: [[0.0; 4]; 2],
    lp: [const { [const { Biquad::new() }; 4] }; 2],
    ap: [const { [const { DelayLine::new() }; 2] }; 2],
    aps: [[0.0; 2]; 2],
    lfo: [const { Lfo::new() }; 4],
});
persist_mut!(REVERB: Reverb = Reverb {
    dl: [const { DelayLine::new() }; 2],
    env: [0.0; 2],
});

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

    VOICE.with_mut(|voice| {
        CHORUS.with_mut(|chorus| {
            COMBS.with_mut(|combs| {
                REVERB.with_mut(|reverb| {
                    // LFO init
                    for k in 0..8 {
                        chorus.lfo[k].init(sr, CH_LFO_HZ[k]);
                    }
                    for k in 0..4 {
                        combs.lfo[k].init(sr, COMB_LFO_HZ[k]);
                    }
                    voice.lfo_trem.init(sr, TREM_HZ);
                    voice.lfo_trem.set_waveform(Waveform::Triangle);

                    for ch in 0..nch {
                        voice.lp[ch].set_coeffs(lpc);
                        for k in 0..3 {
                            voice.formants[ch][k].set_coeffs(formant_c[k]);
                        }
                        voice.whisper_bp[ch].set_coeffs(whisper_bpc);
                        voice.whisper_hs[ch].set_coeffs(whisper_hsc);
                        for k in 0..4 {
                            combs.lp[ch][k].set_coeffs(comb_lpc);
                        }
                    }

                    let mut wet: [f64; 2] = [0.0; 2];

                    for f in 0..ctx.frames() {
                        let chl: [f64; 8] = [
                            chorus.lfo[0].tick(),
                            chorus.lfo[1].tick(),
                            chorus.lfo[2].tick(),
                            chorus.lfo[3].tick(),
                            chorus.lfo[4].tick(),
                            chorus.lfo[5].tick(),
                            chorus.lfo[6].tick(),
                            chorus.lfo[7].tick(),
                        ];
                        let cbl: [f64; 4] = [
                            combs.lfo[0].tick(),
                            combs.lfo[1].tick(),
                            combs.lfo[2].tick(),
                            combs.lfo[3].tick(),
                        ];
                        let trem = voice.lfo_trem.tick();
                        let trem_gain = 1.0 - trem_depth * (1.0 - (trem + 1.0) * 0.5);

                        for ch in 0..nch {
                            let dry = ctx.input(ch, f) as f64;

                            // Stage A: lowpass formant softening
                            let mut x = voice.lp[ch].process_sample(dry);

                            // Stage B: vowel formant peaks
                            x = voice.formants[ch][0].process_sample(x);
                            x = voice.formants[ch][1].process_sample(x);
                            x = voice.formants[ch][2].process_sample(x);

                            // Stage C: 8-voice chorus
                            chorus.dl[ch].write(x as f32);
                            let d0 = (ch_d[0] + chl[0] * voice_depth).max(1.0);
                            let d1 = (ch_d[1] + chl[1] * voice_depth).max(1.0);
                            let d2 = (ch_d[2] + chl[2] * voice_depth).max(1.0);
                            let d3 = (ch_d[3] + chl[3] * voice_depth).max(1.0);
                            let d4 = (ch_d[4] + chl[4] * voice_depth).max(1.0);
                            let d5 = (ch_d[5] + chl[5] * voice_depth).max(1.0);
                            let d6 = (ch_d[6] + chl[6] * voice_depth).max(1.0);
                            let d7 = (ch_d[7] + chl[7] * voice_depth).max(1.0);
                            let csum = (chorus.dl[ch].read(d0) as f64
                                + chorus.dl[ch].read(d1) as f64
                                + chorus.dl[ch].read(d2) as f64
                                + chorus.dl[ch].read(d3) as f64
                                + chorus.dl[ch].read(d4) as f64
                                + chorus.dl[ch].read(d5) as f64
                                + chorus.dl[ch].read(d6) as f64
                                + chorus.dl[ch].read(d7) as f64)
                                * 0.125;

                            // Stage D: reversed-attack envelope shaper on delayed dry
                            reverb.dl[ch].write(dry as f32);
                            let rev_tap = reverb.dl[ch].read(rev_d) as f64;
                            let target = rev_tap.abs();
                            reverb.env[ch] = rev_alpha * reverb.env[ch] + one_minus_rev * target;
                            let chorus_voice = csum * (0.4 + 1.6 * reverb.env[ch]);

                            // Stage E: whisper layer (parallel)
                            let mut wb = voice.whisper_bp[ch].process_sample(x);
                            wb = (wb * 1.5).tanh();
                            wb = voice.whisper_hs[ch].process_sample(wb);
                            let whisper_voice = wb * whisper;

                            // Stage F: cathedral wash — 4 modulated comb filters
                            let wash_in = chorus_voice;
                            let cw0 = (comb_d[0] + cbl[0] * comb_depth).max(1.0);
                            let cw1 = (comb_d[1] + cbl[1] * comb_depth).max(1.0);
                            let cw2 = (comb_d[2] + cbl[2] * comb_depth).max(1.0);
                            let cw3 = (comb_d[3] + cbl[3] * comb_depth).max(1.0);
                            let f0 = combs.lp[ch][0].process_sample(combs.fb_buf[ch][0]);
                            let f1 = combs.lp[ch][1].process_sample(combs.fb_buf[ch][1]);
                            let f2 = combs.lp[ch][2].process_sample(combs.fb_buf[ch][2]);
                            let f3 = combs.lp[ch][3].process_sample(combs.fb_buf[ch][3]);
                            combs.dl[ch][0].write((wash_in + COMB_FB * f0) as f32);
                            combs.dl[ch][1].write((wash_in + COMB_FB * f1) as f32);
                            combs.dl[ch][2].write((wash_in + COMB_FB * f2) as f32);
                            combs.dl[ch][3].write((wash_in + COMB_FB * f3) as f32);
                            combs.fb_buf[ch][0] = combs.dl[ch][0].read(cw0) as f64;
                            combs.fb_buf[ch][1] = combs.dl[ch][1].read(cw1) as f64;
                            combs.fb_buf[ch][2] = combs.dl[ch][2].read(cw2) as f64;
                            combs.fb_buf[ch][3] = combs.dl[ch][3].read(cw3) as f64;
                            let cathedral = (combs.fb_buf[ch][0]
                                + combs.fb_buf[ch][1]
                                + combs.fb_buf[ch][2]
                                + combs.fb_buf[ch][3])
                                * 0.25;

                            // Stage G: 2 cascaded Schroeder allpass diffusers
                            let mut sig = chorus_voice + whisper_voice + cathedral * wash;
                            for k in 0..2 {
                                let vd = combs.aps[ch][k];
                                let vn = sig + AP_G * vd;
                                combs.ap[ch][k].write(vn as f32);
                                combs.aps[ch][k] = combs.ap[ch][k].read(ap_d[k]) as f64;
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
}
