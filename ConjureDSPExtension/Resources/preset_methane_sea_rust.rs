// Methane Sea — bubbles surfacing from an alien ocean on Titan.
//
// Cross-channel ping-pong delay (L delay's tap routes to R's input and
// vice versa — true L↔R routing) with per-channel tap positions modulated
// by two coprime LFOs at 0.31 / 0.47 Hz, and the modulation depth itself
// swept by a very slow 0.07 Hz "sweep" LFO → sub drone bed (rectified |dry|
// → 80 Hz LP) → dark lowpass (2 kHz) on the wet bus → final mix.
//
// Distinct from Underwater Spy: sparse alien ocean bubbles vs lush
// submerged warmth. Second preset with true cross-channel routing (after
// Tin Can Telephone) — but here the routing is a ping-pong delay rather
// than a fast feedback clip loop.
//
// Params:
//   RIPPLE (pct) — ping-pong feedback amount
//   BUBBLE (pct) — base tap LFO depth
//   DRONE  (pct) — sub drone level
//   SWEEP  (pct) — slow sweep LFO depth (modulates tap depth)
//   MIX          — wet/dry blend

use conjuredsp::*;
setup!();

params! {
    RIPPLE = pct().default(60.0),
    BUBBLE = pct().default(55.0),
    DRONE = pct().default(50.0),
    SWEEP = pct().default(60.0),
    MIX = mix().default(0.55),
}

const MAX_DL: usize = 32000;

const TAP_BASE_MS: f64 = 220.0;
const TAP_LFO_HZ: [f64; 2] = [0.31, 0.47];
const SWEEP_HZ: f64 = 0.07;

static mut DELAY: [DelayLine<MAX_DL>; 2] = [DelayLine::new(); 2];
static mut SUB_LP: [Biquad; 2] = [Biquad::new(); 2];
static mut WET_LP: [Biquad; 2] = [Biquad::new(); 2];
static mut TAP_LFO: [Lfo; 2] = [Lfo::new(); 2];
static mut SWEEP_LFO: Lfo = Lfo::new();

#[no_mangle]
pub extern "C" fn process(
    input: *const f32, output: *mut f32,
    channels: i32, frame_count: i32, sample_rate: f32,
) {
    let ctx = ctx(input, output, channels, frame_count, sample_rate);
    let sr = ctx.sample_rate() as f64;

    unsafe {
        let ripple = ctx.param(RIPPLE) as f64 / 100.0;
        let bubble = ctx.param(BUBBLE) as f64 / 100.0;
        let drone = ctx.param(DRONE) as f64 / 100.0;
        let sweep = ctx.param(SWEEP) as f64 / 100.0;
        let mx = ctx.param(MIX) as f64;

        let sub_lpc = BiquadCoeffs::lowpass(80.0, 0.707, sr);
        let wet_lpc = BiquadCoeffs::lowpass(2000.0, 0.707, sr);

        for k in 0..2 {
            TAP_LFO[k].init(sr, TAP_LFO_HZ[k]);
        }
        SWEEP_LFO.init(sr, SWEEP_HZ);

        let nch = ctx.channels().min(2);
        for ch in 0..nch {
            SUB_LP[ch].set_coeffs(sub_lpc);
            WET_LP[ch].set_coeffs(wet_lpc);
        }

        let tap_base = TAP_BASE_MS * 0.001 * sr;
        let base_depth = (10.0 + 40.0 * bubble) * 0.001 * sr;
        let sweep_depth = 0.6 * sweep;
        let fb_amt = 0.45 + 0.45 * ripple;
        let drone_gain = 0.5 + 1.2 * drone;

        for f in 0..ctx.frames() {
            let tl = TAP_LFO[0].tick();
            let tr = TAP_LFO[1].tick();
            let sw = SWEEP_LFO.tick();
            let depth_mod = (1.0 - sweep_depth) + sweep_depth * (0.5 + 0.5 * sw);
            let mut tap_l = tap_base + tl * base_depth * depth_mod;
            let mut tap_r = tap_base + tr * base_depth * depth_mod;
            if tap_l < 1.0 {
                tap_l = 1.0;
            }
            if tap_r < 1.0 {
                tap_r = 1.0;
            }

            if nch >= 2 {
                let fb_from_l = DELAY[0].read(tap_l) as f64;
                let fb_from_r = DELAY[1].read(tap_r) as f64;

                let l_dry = ctx.input(0, f) as f64;
                let r_dry = ctx.input(1, f) as f64;

                DELAY[0].write((l_dry + fb_from_r * fb_amt) as f32);
                DELAY[1].write((r_dry + fb_from_l * fb_amt) as f32);

                let l_sub = SUB_LP[0].process_sample(l_dry.abs()) * drone_gain;
                let r_sub = SUB_LP[1].process_sample(r_dry.abs()) * drone_gain;

                let l_wet_raw = fb_from_r + l_sub;
                let r_wet_raw = fb_from_l + r_sub;

                let l_wet = WET_LP[0].process_sample(l_wet_raw);
                let r_wet = WET_LP[1].process_sample(r_wet_raw);

                ctx.set_output(0, f, (l_dry * (1.0 - mx) + l_wet * mx) as f32);
                ctx.set_output(1, f, (r_dry * (1.0 - mx) + r_wet * mx) as f32);
            } else {
                let fb_out = DELAY[0].read(tap_l) as f64;
                let dry = ctx.input(0, f) as f64;
                DELAY[0].write((dry + fb_out * fb_amt) as f32);
                let sub_voice = SUB_LP[0].process_sample(dry.abs()) * drone_gain;
                let wet_raw = fb_out + sub_voice;
                let wet = WET_LP[0].process_sample(wet_raw);
                ctx.set_output(0, f, (dry * (1.0 - mx) + wet * mx) as f32);
            }
        }
    }
}
