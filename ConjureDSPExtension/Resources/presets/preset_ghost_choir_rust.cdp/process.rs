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

static mut LP: [Biquad; 2] = [Biquad::new(); 2];
static mut FORMANTS: [[Biquad; 3]; 2] = [[Biquad::new(); 3]; 2];
static mut CHORUS: [DelayLine<MAX_DL>; 2] = [DelayLine::new(); 2];
static mut REV_DL: [DelayLine<MAX_DL>; 2] = [DelayLine::new(); 2];
static mut REV_ENV: [f64; 2] = [0.0; 2];
static mut WHISPER_BP: [Biquad; 2] = [Biquad::new(); 2];
static mut WHISPER_HS: [Biquad; 2] = [Biquad::new(); 2];
static mut COMBS: [[DelayLine<MAX_DL>; 4]; 2] = [[DelayLine::new(); 4]; 2];
static mut COMB_FB_BUF: [[f64; 4]; 2] = [[0.0; 4]; 2];
static mut COMB_LP: [[Biquad; 4]; 2] = [[Biquad::new(); 4]; 2];
static mut AP: [[DelayLine<MAX_DL>; 2]; 2] = [[DelayLine::new(); 2]; 2];
static mut APS: [[f64; 2]; 2] = [[0.0; 2]; 2];
static mut LFO_CHORUS: [Lfo; 8] = [Lfo::new(); 8];
static mut LFO_COMBS: [Lfo; 4] = [Lfo::new(); 4];
static mut LFO_TREM: Lfo = Lfo::new();

process! { ctx =>
    let sr = ctx.sample_rate() as f64;

    unsafe {
        let voices_ms = ctx.param(VOICES) as f64;
        let air_hz = ctx.param(AIR) as f64;
        let whisper = ctx.param(WHISPER) as f64 / 100.0;
        let wash = ctx.param(WASH) as f64 / 100.0;
        let mx = ctx.param(MIX) as f64;

        // LFO init
        for k in 0..8 {
            LFO_CHORUS[k].init(sr, CH_LFO_HZ[k]);
        }
        for k in 0..4 {
            LFO_COMBS[k].init(sr, COMB_LFO_HZ[k]);
        }
        LFO_TREM.init(sr, TREM_HZ);
        LFO_TREM.set_waveform(Waveform::Triangle);

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
        for ch in 0..nch {
            LP[ch].set_coeffs(lpc);
            for k in 0..3 {
                FORMANTS[ch][k].set_coeffs(formant_c[k]);
            }
            WHISPER_BP[ch].set_coeffs(whisper_bpc);
            WHISPER_HS[ch].set_coeffs(whisper_hsc);
            for k in 0..4 {
                COMB_LP[ch][k].set_coeffs(comb_lpc);
            }
        }

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

        let mut wet: [f64; 2] = [0.0; 2];

        for f in 0..ctx.frames() {
            let chl: [f64; 8] = [
                LFO_CHORUS[0].tick(),
                LFO_CHORUS[1].tick(),
                LFO_CHORUS[2].tick(),
                LFO_CHORUS[3].tick(),
                LFO_CHORUS[4].tick(),
                LFO_CHORUS[5].tick(),
                LFO_CHORUS[6].tick(),
                LFO_CHORUS[7].tick(),
            ];
            let cbl: [f64; 4] = [
                LFO_COMBS[0].tick(),
                LFO_COMBS[1].tick(),
                LFO_COMBS[2].tick(),
                LFO_COMBS[3].tick(),
            ];
            let trem = LFO_TREM.tick();
            let trem_gain = 1.0 - trem_depth * (1.0 - (trem + 1.0) * 0.5);

            for ch in 0..nch {
                let dry = ctx.input(ch, f) as f64;

                // Stage A: lowpass formant softening
                let mut x = LP[ch].process_sample(dry);

                // Stage B: vowel formant peaks
                x = FORMANTS[ch][0].process_sample(x);
                x = FORMANTS[ch][1].process_sample(x);
                x = FORMANTS[ch][2].process_sample(x);

                // Stage C: 8-voice chorus
                CHORUS[ch].write(x as f32);
                let d0 = (ch_d[0] + chl[0] * voice_depth).max(1.0);
                let d1 = (ch_d[1] + chl[1] * voice_depth).max(1.0);
                let d2 = (ch_d[2] + chl[2] * voice_depth).max(1.0);
                let d3 = (ch_d[3] + chl[3] * voice_depth).max(1.0);
                let d4 = (ch_d[4] + chl[4] * voice_depth).max(1.0);
                let d5 = (ch_d[5] + chl[5] * voice_depth).max(1.0);
                let d6 = (ch_d[6] + chl[6] * voice_depth).max(1.0);
                let d7 = (ch_d[7] + chl[7] * voice_depth).max(1.0);
                let csum = (CHORUS[ch].read(d0) as f64
                    + CHORUS[ch].read(d1) as f64
                    + CHORUS[ch].read(d2) as f64
                    + CHORUS[ch].read(d3) as f64
                    + CHORUS[ch].read(d4) as f64
                    + CHORUS[ch].read(d5) as f64
                    + CHORUS[ch].read(d6) as f64
                    + CHORUS[ch].read(d7) as f64)
                    * 0.125;

                // Stage D: reversed-attack envelope shaper on delayed dry
                REV_DL[ch].write(dry as f32);
                let rev_tap = REV_DL[ch].read(rev_d) as f64;
                let target = rev_tap.abs();
                REV_ENV[ch] = rev_alpha * REV_ENV[ch] + one_minus_rev * target;
                let chorus_voice = csum * (0.4 + 1.6 * REV_ENV[ch]);

                // Stage E: whisper layer (parallel)
                let mut wb = WHISPER_BP[ch].process_sample(x);
                wb = (wb * 1.5).tanh();
                wb = WHISPER_HS[ch].process_sample(wb);
                let whisper_voice = wb * whisper;

                // Stage F: cathedral wash — 4 modulated comb filters
                let wash_in = chorus_voice;
                let cw0 = (comb_d[0] + cbl[0] * comb_depth).max(1.0);
                let cw1 = (comb_d[1] + cbl[1] * comb_depth).max(1.0);
                let cw2 = (comb_d[2] + cbl[2] * comb_depth).max(1.0);
                let cw3 = (comb_d[3] + cbl[3] * comb_depth).max(1.0);
                let f0 = COMB_LP[ch][0].process_sample(COMB_FB_BUF[ch][0]);
                let f1 = COMB_LP[ch][1].process_sample(COMB_FB_BUF[ch][1]);
                let f2 = COMB_LP[ch][2].process_sample(COMB_FB_BUF[ch][2]);
                let f3 = COMB_LP[ch][3].process_sample(COMB_FB_BUF[ch][3]);
                COMBS[ch][0].write((wash_in + COMB_FB * f0) as f32);
                COMBS[ch][1].write((wash_in + COMB_FB * f1) as f32);
                COMBS[ch][2].write((wash_in + COMB_FB * f2) as f32);
                COMBS[ch][3].write((wash_in + COMB_FB * f3) as f32);
                COMB_FB_BUF[ch][0] = COMBS[ch][0].read(cw0) as f64;
                COMB_FB_BUF[ch][1] = COMBS[ch][1].read(cw1) as f64;
                COMB_FB_BUF[ch][2] = COMBS[ch][2].read(cw2) as f64;
                COMB_FB_BUF[ch][3] = COMBS[ch][3].read(cw3) as f64;
                let cathedral = (COMB_FB_BUF[ch][0]
                    + COMB_FB_BUF[ch][1]
                    + COMB_FB_BUF[ch][2]
                    + COMB_FB_BUF[ch][3])
                    * 0.25;

                // Stage G: 2 cascaded Schroeder allpass diffusers
                let mut sig = chorus_voice + whisper_voice + cathedral * wash;
                for k in 0..2 {
                    let vd = APS[ch][k];
                    let vn = sig + AP_G * vd;
                    AP[ch][k].write(vn as f32);
                    APS[ch][k] = AP[ch][k].read(ap_d[k]) as f64;
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
    }
}
