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
setup!();

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

static mut MODAL: [[Biquad; 6]; 2] = [[Biquad::new(); 6]; 2];
static mut SHIMMER_DL: [DelayLine<MAX_DL>; 2] = [DelayLine::new(); 2];
static mut GRAN_DL: [DelayLine<MAX_DL>; 2] = [DelayLine::new(); 2];
static mut SUB_LP: [Biquad; 2] = [Biquad::new(); 2];
static mut SHIM_HP: [Biquad; 2] = [Biquad::new(); 2];
static mut COMBS: [[DelayLine<MAX_DL>; 4]; 2] = [[DelayLine::new(); 4]; 2];
static mut COMB_FB_BUF: [[f64; 4]; 2] = [[0.0; 4]; 2];
static mut COMB_LP: [[Biquad; 4]; 2] = [[Biquad::new(); 4]; 2];
static mut SHIM_PHASE: f64 = 0.0;
static mut GRAN_PHASE: f64 = 0.0;

#[no_mangle]
pub extern "C" fn process(
    input: *const f32, output: *mut f32,
    channels: i32, frame_count: i32, sample_rate: f32,
) {
    let ctx = ctx(input, output, channels, frame_count, sample_rate);
    let sr = ctx.sample_rate() as f64;

    unsafe {
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
        for ch in 0..nch {
            for k in 0..6 {
                MODAL[ch][k].set_coeffs(modal_c[k]);
            }
            SUB_LP[ch].set_coeffs(sub_lpc);
            SHIM_HP[ch].set_coeffs(shim_hpc);
            for k in 0..4 {
                COMB_LP[ch][k].set_coeffs(comb_lpc);
            }
        }

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

        let modal_gain: f64 = 1.0 / 6.0;
        let sub_gain: f64 = 0.4;

        for f in 0..ctx.frames() {
            let sh_ph0 = SHIM_PHASE;
            let sh_ph1 = (SHIM_PHASE + 0.5) % 1.0;
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
            SHIM_PHASE = (SHIM_PHASE + shim_rate) % 1.0;

            let gr_ph0 = GRAN_PHASE;
            let gr_ph1 = (GRAN_PHASE + 0.5) % 1.0;
            let gr_w0_ = (core::f64::consts::PI * gr_ph0).sin();
            let gr_w0 = gr_w0_ * gr_w0_;
            let gr_w1_ = (core::f64::consts::PI * gr_ph1).sin();
            let gr_w1 = gr_w1_ * gr_w1_;
            let gr_read0 = gran_base + gr_ph0 * gran_grain;
            let gr_read1 = gran_base + gr_ph1 * gran_grain;
            GRAN_PHASE = (GRAN_PHASE + gran_rate) % 1.0;

            for ch in 0..nch {
                let dry = ctx.input(ch, f) as f64;

                // Stage A: modal resonator bank (6 parallel high-Q bandpasses)
                let m0 = MODAL[ch][0].process_sample(dry);
                let m1 = MODAL[ch][1].process_sample(dry);
                let m2 = MODAL[ch][2].process_sample(dry);
                let m3 = MODAL[ch][3].process_sample(dry);
                let m4 = MODAL[ch][4].process_sample(dry);
                let m5 = MODAL[ch][5].process_sample(dry);
                let modal_sum = (m0 + m1 + m2 + m3 + m4 + m5) * modal_gain;

                // Stage B: octave-up crystalline shimmer (dual-tap pitch shifter)
                SHIMMER_DL[ch].write(modal_sum as f32);
                let sg0 = SHIMMER_DL[ch].read(sh_read0) as f64;
                let sg1 = SHIMMER_DL[ch].read(sh_read1) as f64;
                let mut shim_voice = (sh_w0 * sg0 + sh_w1 * sg1) * shimmer;
                shim_voice = SHIM_HP[ch].process_sample(shim_voice);

                // Stage C: granular slow-motion (octave down, dual-tap shifter)
                GRAN_DL[ch].write(modal_sum as f32);
                let ng0 = GRAN_DL[ch].read(gr_read0) as f64;
                let ng1 = GRAN_DL[ch].read(gr_read1) as f64;
                let gran_voice = (gr_w0 * ng0 + gr_w1 * ng1) * slowmo;

                // Stage D: sub-octave impact thud (rectify → LP → gain)
                let sub_voice = SUB_LP[ch].process_sample(dry.abs()) * sub_gain;

                // Stage E: 4-comb reverb tail
                let comb_in = modal_sum + shim_voice + gran_voice;
                let f0 = COMB_LP[ch][0].process_sample(COMB_FB_BUF[ch][0]);
                let f1 = COMB_LP[ch][1].process_sample(COMB_FB_BUF[ch][1]);
                let f2 = COMB_LP[ch][2].process_sample(COMB_FB_BUF[ch][2]);
                let f3 = COMB_LP[ch][3].process_sample(COMB_FB_BUF[ch][3]);
                COMBS[ch][0].write((comb_in + comb_fb_amt * f0) as f32);
                COMBS[ch][1].write((comb_in + comb_fb_amt * f1) as f32);
                COMBS[ch][2].write((comb_in + comb_fb_amt * f2) as f32);
                COMBS[ch][3].write((comb_in + comb_fb_amt * f3) as f32);
                COMB_FB_BUF[ch][0] = COMBS[ch][0].read(comb_d[0]) as f64;
                COMB_FB_BUF[ch][1] = COMBS[ch][1].read(comb_d[1]) as f64;
                COMB_FB_BUF[ch][2] = COMBS[ch][2].read(comb_d[2]) as f64;
                COMB_FB_BUF[ch][3] = COMBS[ch][3].read(comb_d[3]) as f64;
                let tail = (COMB_FB_BUF[ch][0]
                    + COMB_FB_BUF[ch][1]
                    + COMB_FB_BUF[ch][2]
                    + COMB_FB_BUF[ch][3])
                    * 0.25;

                // Stage F: final wet sum + mix
                let wet = modal_sum + shim_voice + gran_voice + sub_voice + tail;
                ctx.set_output(ch, f, (dry * (1.0 - mx) + wet * mx) as f32);
            }
        }
    }
}
