// Hailstorm Lullaby — ice on a tin roof over a sleeping child.
//
// Fast-attack envelope follower on |dry| → threshold-gated hail impact
// (deterministic LCG-based noise burst multiplied by the envelope → tin-roof
// clatter) → soft sub-pad bed (80 Hz LP of rectified input) → 2 allpass +
// 2-comb dark hall reverb whose wet amount is MODULATED by the envelope
// (envelope-gated reverb — the tail only opens on transients) → final mix.
//
// First envelope-gated reverb in the set. Juxtaposes stochastic percussive
// transients against a gentle sub pad.
//
// Params:
//   IMPACT (pct) — hail noise level
//   PATTER (pct) — envelope threshold (lower → more hail)
//   SUBPAD (pct) — sub-pad bed level
//   HALL   (pct) — reverb feedback (dark hall tail)
//   MIX          — wet/dry blend

use conjuredsp::*;
setup!();

params! {
    IMPACT = pct().default(65.0),
    PATTER = pct().default(50.0),
    SUBPAD = pct().default(55.0),
    HALL = pct().default(60.0),
    MIX = mix().default(0.55),
}

const MAX_DL: usize = 36000;

const AP_MS: [f64; 2] = [7.3, 11.1];
const AP_G: f64 = 0.55;
const COMB_MS: [f64; 2] = [113.0, 167.0];

static mut ENV: [f64; 2] = [0.0; 2];
static mut SUB_LP: [Biquad; 2] = [Biquad::new(); 2];
static mut AP: [[DelayLine<MAX_DL>; 2]; 2] = [[DelayLine::new(); 2]; 2];
static mut APS: [[f64; 2]; 2] = [[0.0; 2]; 2];
static mut COMBS: [[DelayLine<MAX_DL>; 2]; 2] = [[DelayLine::new(); 2]; 2];
static mut COMB_LP: [[Biquad; 2]; 2] = [[Biquad::new(); 2]; 2];
static mut COMB_FB_BUF: [[f64; 2]; 2] = [[0.0; 2]; 2];
static mut LCG_STATE: u64 = 0x13579BDF;

#[no_mangle]
pub extern "C" fn process(
    input: *const f32, output: *mut f32,
    channel_count: i32, frame_count: i32, sample_rate: f32,
) {
    let ctx = ctx(input, output, channel_count, frame_count, sample_rate);
    let sr = ctx.sample_rate() as f64;

    unsafe {
        let impact = ctx.param(IMPACT) as f64 / 100.0;
        let patter = ctx.param(PATTER) as f64 / 100.0;
        let subpad = ctx.param(SUBPAD) as f64 / 100.0;
        let hall = ctx.param(HALL) as f64 / 100.0;
        let mx = ctx.param(MIX) as f64;

        let sub_lpc = BiquadCoeffs::lowpass(80.0, 0.707, sr);
        let comb_lpc = BiquadCoeffs::lowpass(1800.0, 0.707, sr);
        let nch = ctx.channels().min(2);
        for ch in 0..nch {
            SUB_LP[ch].set_coeffs(sub_lpc);
            for k in 0..2 {
                COMB_LP[ch][k].set_coeffs(comb_lpc);
            }
        }

        let attack_alpha = 1.0 - (-1.0 / (0.002 * sr)).exp();
        let release_alpha = 1.0 - (-1.0 / (0.080 * sr)).exp();

        let ap_d: [f64; 2] = [
            (AP_MS[0] * 0.001 * sr).max(1.0),
            (AP_MS[1] * 0.001 * sr).max(1.0),
        ];
        let comb_d: [f64; 2] = [
            COMB_MS[0] * 0.001 * sr,
            COMB_MS[1] * 0.001 * sr,
        ];
        let comb_fb_amt = 0.55 + 0.30 * hall;

        let thresh = 0.02 + 0.25 * (1.0 - patter);
        let hail_gain = 2.0 + 4.0 * impact;
        let sub_gain = 0.6 + 1.4 * subpad;

        for f in 0..ctx.frames() {
            LCG_STATE = (LCG_STATE.wrapping_mul(1103515245).wrapping_add(12345)) & 0x7FFFFFFF;
            let noise = (LCG_STATE as f64 / 2147483647.0) * 2.0 - 1.0;

            for ch in 0..nch {
                let dry = ctx.input(ch, f) as f64;

                let absx = dry.abs();
                if absx > ENV[ch] {
                    ENV[ch] += (absx - ENV[ch]) * attack_alpha;
                } else {
                    ENV[ch] += (absx - ENV[ch]) * release_alpha;
                }
                let env = ENV[ch];

                let hail = if env > thresh {
                    noise * env * hail_gain
                } else {
                    0.0
                };

                let sub_voice = SUB_LP[ch].process_sample(absx) * sub_gain;

                let mut sig = hail + sub_voice * 0.3;
                for k in 0..2 {
                    let vd = APS[ch][k];
                    let vn = sig + AP_G * vd;
                    AP[ch][k].write(vn as f32);
                    APS[ch][k] = AP[ch][k].read(ap_d[k]) as f64;
                    sig = vd - AP_G * vn;
                }

                let mut tail_sum: f64 = 0.0;
                for k in 0..2 {
                    let f_in = COMB_LP[ch][k].process_sample(COMB_FB_BUF[ch][k]);
                    COMBS[ch][k].write((sig + comb_fb_amt * f_in) as f32);
                    COMB_FB_BUF[ch][k] = COMBS[ch][k].read(comb_d[k]) as f64;
                    tail_sum += COMB_FB_BUF[ch][k];
                }
                tail_sum *= 0.5;

                let env_scaled = env * 3.0;
                let env_clamped = if env_scaled > 1.0 { 1.0 } else { env_scaled };
                let gate_amt = 0.25 + 0.75 * env_clamped;
                let wet = hail + sub_voice + tail_sum * gate_amt;

                ctx.set_output(ch, f, (dry * (1.0 - mx) + wet * mx) as f32);
            }
        }
    }
}
