// Last Transmission — a dying SOS broadcast through static.
//
// Narrow telegraph bandpass (800 Hz center, high Q) → dropout envelope
// (3 slow LFOs at 0.19 / 0.43 / 0.8 Hz summed; when sum falls below a
// dropout-scaled threshold the signal goes silent) → soft tanh fuzz
// scaled by the dropout envelope → small far reverb (2 allpass + short
// comb) → final mix.
//
// Distinct from Alien Radio: intimate, decaying single-channel transmission
// rather than wide stereo broadcast. First preset where dropout density is
// the primary expressive control.
//
// Params:
//   RADIO    (pct) — bandpass narrowness (Q)
//   DROPOUT  (pct) — dropout density
//   FUZZ     (pct) — tanh saturation drive
//   DISTANCE (pct) — far-reverb amount
//   MIX            — wet/dry blend

use conjuredsp::*;
setup!();

params! {
    RADIO = pct().default(70.0),
    DROPOUT = pct().default(55.0),
    FUZZ = pct().default(50.0),
    DISTANCE = pct().default(40.0),
    MIX = mix().default(0.6),
}

const MAX_DL: usize = 16000;

const BP_HZ: f64 = 800.0;
const DROPOUT_HZ: [f64; 3] = [0.19, 0.43, 0.8];
const AP_MS: [f64; 2] = [5.3, 7.9];
const AP_G: f64 = 0.5;
const COMB_MS: f64 = 67.0;

static mut BP: [Biquad; 2] = [Biquad::new(); 2];
static mut DROPOUT_LFO: [Lfo; 3] = [Lfo::new(); 3];
static mut AP: [[DelayLine<MAX_DL>; 2]; 2] = [[DelayLine::new(); 2]; 2];
static mut APS: [[f64; 2]; 2] = [[0.0; 2]; 2];
static mut COMB: [DelayLine<MAX_DL>; 2] = [DelayLine::new(); 2];
static mut COMB_FB: [f64; 2] = [0.0; 2];
static mut COMB_LP: [Biquad; 2] = [Biquad::new(); 2];

#[no_mangle]
pub extern "C" fn process(
    input: *const f32, output: *mut f32,
    channel_count: i32, frame_count: i32, sample_rate: f32,
) {
    let ctx = ctx(input, output, channel_count, frame_count, sample_rate);
    let sr = ctx.sample_rate() as f64;

    unsafe {
        let radio = ctx.param(RADIO) as f64 / 100.0;
        let dropout = ctx.param(DROPOUT) as f64 / 100.0;
        let fuzz = ctx.param(FUZZ) as f64 / 100.0;
        let distance = ctx.param(DISTANCE) as f64 / 100.0;
        let mx = ctx.param(MIX) as f64;

        let bp_q = 4.0 + 12.0 * radio;
        let bp_c = BiquadCoeffs::bandpass(BP_HZ, bp_q, sr);
        let comb_lpc = BiquadCoeffs::lowpass(1600.0, 0.707, sr);

        for k in 0..3 {
            DROPOUT_LFO[k].init(sr, DROPOUT_HZ[k]);
        }

        let nch = ctx.channels().min(2);
        for ch in 0..nch {
            BP[ch].set_coeffs(bp_c);
            COMB_LP[ch].set_coeffs(comb_lpc);
        }

        let ap_d: [f64; 2] = [
            (AP_MS[0] * 0.001 * sr).max(1.0),
            (AP_MS[1] * 0.001 * sr).max(1.0),
        ];
        let comb_d = COMB_MS * 0.001 * sr;
        let comb_fb_amt = 0.45 + 0.40 * distance;

        let drive = 1.0 + 5.0 * fuzz;
        let drop_thresh = -0.4 + 1.2 * dropout;

        for f in 0..ctx.frames() {
            let d0 = DROPOUT_LFO[0].tick();
            let d1 = DROPOUT_LFO[1].tick();
            let d2 = DROPOUT_LFO[2].tick();
            let drop_env = (d0 + d1 + d2) / 3.0;
            let gate = drop_env - drop_thresh;
            let gate_val = if gate < 0.0 {
                0.0
            } else if gate > 0.3 {
                1.0
            } else {
                gate / 0.3
            };

            for ch in 0..nch {
                let dry = ctx.input(ch, f) as f64;

                let filtered = BP[ch].process_sample(dry);

                let gated = filtered * gate_val;

                let fuzzed = (gated * drive).tanh() / drive;

                let mut sig = fuzzed;
                for k in 0..2 {
                    let vd = APS[ch][k];
                    let vn = sig + AP_G * vd;
                    AP[ch][k].write(vn as f32);
                    APS[ch][k] = AP[ch][k].read(ap_d[k]) as f64;
                    sig = vd - AP_G * vn;
                }

                let f_in = COMB_LP[ch].process_sample(COMB_FB[ch]);
                COMB[ch].write((sig + comb_fb_amt * f_in) as f32);
                COMB_FB[ch] = COMB[ch].read(comb_d) as f64;

                let wet = fuzzed + sig * 0.4 + COMB_FB[ch] * 0.5;
                ctx.set_output(ch, f, (dry * (1.0 - mx) + wet * mx) as f32);
            }
        }
    }
}
