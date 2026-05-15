// Tin Can Telephone — two voices on a string between cans.
//
// Aggressive narrow bandpass (~1 kHz, high Q) per channel → cross-channel
// feedback routing (L[n] input = L_dry + (previous frame's R wet) * fb_amt,
// and vice versa — true L↔R routing, NOT M/S widening) → asymmetric soft
// clip (hard on positive, soft on negative) → occasional dropout gate (slow
// LFO + sparse threshold) → final mix.
//
// First preset in the set with cross-channel L↔R feedback. Intimate stereo
// image (the stereo separation is the string, not the room).
//
// Controls:
//   CAN     (pct) — bandpass narrowness (Q)
//   STRING  (pct) — cross-channel feedback amount
//   CLIP    (pct) — asymmetric clip drive
//   DROPOUT (pct) — dropout density
//   MIX           — wet/dry blend

use conjuredsp::*;
params! {
    CAN = pct().default(65.0),
    STRING = pct().default(50.0),
    CLIP = pct().default(55.0),
    DROPOUT = pct().default(30.0),
    MIX = mix().default(0.6),
}

const BP_HZ: f64 = 1000.0;
const DROPOUT_HZ: f64 = 0.37;

persist_mut!(BP: [Biquad; 2] = [const { Biquad::new() }; 2]);
persist_mut!(CROSS_FB: [f64; 2] = [0.0; 2]);
persist_mut!(DROPOUT_LFO: Lfo = Lfo::new());

#[inline]
fn asym_clip(x: f64, drive: f64) -> f64 {
    if x >= 0.0 {
        (x * drive * 1.8).tanh() / (drive * 1.8)
    } else {
        (x * drive * 0.7).tanh() / (drive * 0.7)
    }
}

process! { ctx =>
    let sr = ctx.sample_rate() as f64;

    let can = ctx.param(CAN) as f64 / 100.0;
    let string = ctx.param(STRING) as f64 / 100.0;
    let clip = ctx.param(CLIP) as f64 / 100.0;
    let dropout = ctx.param(DROPOUT) as f64 / 100.0;
    let mx = ctx.param(MIX) as f64;

    let bp_q = 5.0 + 12.0 * can;
    let bp_c = BiquadCoeffs::bandpass(BP_HZ, bp_q, sr);

    let nch = ctx.channels().min(2);

    let fb_amt = 0.75 * string;
    let drive = 1.0 + 5.0 * clip;
    let drop_thresh = -0.6 + 1.2 * dropout;

    BP.with_mut(|bp| {
        CROSS_FB.with_mut(|cross_fb| {
            DROPOUT_LFO.with_mut(|dropout_lfo| {
                dropout_lfo.init(sr, DROPOUT_HZ);

                for ch in 0..nch {
                    bp[ch].set_coeffs(bp_c);
                }

                for f in 0..ctx.frames() {
                    let drop_val = dropout_lfo.tick();
                    let gate = drop_val - drop_thresh;
                    let gate_val = if gate < 0.0 {
                        0.0
                    } else if gate > 0.3 {
                        1.0
                    } else {
                        gate / 0.3
                    };

                    if nch >= 2 {
                        let l_dry = ctx.input(0, f) as f64;
                        let r_dry = ctx.input(1, f) as f64;

                        let l_in = l_dry + cross_fb[1] * fb_amt;
                        let r_in = r_dry + cross_fb[0] * fb_amt;

                        let l_bp = bp[0].process_sample(l_in);
                        let r_bp = bp[1].process_sample(r_in);

                        let l_clip = asym_clip(l_bp, drive);
                        let r_clip = asym_clip(r_bp, drive);

                        let l_wet = l_clip * gate_val;
                        let r_wet = r_clip * gate_val;

                        cross_fb[0] = l_wet;
                        cross_fb[1] = r_wet;

                        ctx.set_output(0, f, (l_dry * (1.0 - mx) + l_wet * mx) as f32);
                        ctx.set_output(1, f, (r_dry * (1.0 - mx) + r_wet * mx) as f32);
                    } else {
                        let dry = ctx.input(0, f) as f64;
                        let x_in = dry + cross_fb[0] * fb_amt;
                        let x_bp = bp[0].process_sample(x_in);
                        let x_clip = asym_clip(x_bp, drive);
                        let wet = x_clip * gate_val;
                        cross_fb[0] = wet;
                        ctx.set_output(0, f, (dry * (1.0 - mx) + wet * mx) as f32);
                    }
                }
            });
        });
    });
}
