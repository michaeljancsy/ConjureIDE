// Lo-Fi Hip Hop — the study beats aesthetic.
//
// Vinyl crackle, tape wobble, gentle bit reduction, and warm filtering.
// Perfect for the "chill beats to study to" aesthetic.

use conjuredsp::*;
setup!();

params! {
    VINYL = param(0.0, 1.0).default(0.4),
    WARMTH = param(0.0, 1.0).default(0.6),
    WOBBLE = param(0.0, 1.0).default(0.3),
    BIT_DEPTH = param(8.0, 16.0).unit("bits").default(12.0),
}

static mut RNG_STATE: u32 = 12345;

fn rng() -> f64 {
    unsafe {
        RNG_STATE = RNG_STATE.wrapping_mul(1664525).wrapping_add(1013904223);
        RNG_STATE as f64 / 4294967296.0
    }
}

static mut LP: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];
static mut HP: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];
static mut DELAYS: [DelayLine<1024>; MAX_CH] = [DelayLine::new(); MAX_CH];
static mut WOW_PHASE: f64 = 0.0;

#[no_mangle]
pub extern "C" fn process(
    input: *const f32,
    output: *mut f32,
    channels: i32,
    frame_count: i32,
    sample_rate: f32,
) {
    let ctx = ctx(input, output, channels, frame_count, sample_rate);
    let sr = sample_rate as f64;

    unsafe {
        let vinyl = ctx.param(VINYL) as f64;
        let warmth = ctx.param(WARMTH) as f64;
        let wobble = ctx.param(WOBBLE) as f64;
        let bit_depth = ctx.param(BIT_DEPTH) as i32;

        let two_pi = 2.0 * core::f64::consts::PI;

        // Warmth = low pass
        let lp_freq = 16000.0 - warmth * 10000.0;
        let levels = (1 << bit_depth) as f64;

        for ch in 0..ctx.channels() {
            LP[ch].set_coeffs(BiquadCoeffs::lowpass(lp_freq, 0.7, sr));
            HP[ch].set_coeffs(BiquadCoeffs::highpass(40.0, 0.7, sr));
        }

        for i in 0..ctx.frames() {
            // Tape wobble
            let wow = (two_pi * WOW_PHASE).sin() * wobble * 3.0;
            WOW_PHASE = (WOW_PHASE + 0.5 / sr) % 1.0;

            for ch in 0..ctx.channels() {
                let x_in = ctx.input(ch, i) as f64;

                // Wobble via modulated delay
                DELAYS[ch].write(x_in as f32);
                let delay = 10.0 + wow;
                let delay_clamped = if delay > 1.0 { delay } else { 1.0 };
                let mut x = DELAYS[ch].read_cubic(delay_clamped) as f64;

                // Warm filtering
                x = LP[ch].process_sample(x);
                x = HP[ch].process_sample(x);

                // Gentle saturation
                x = (x * 1.5).tanh() * 0.75;

                // Bit reduction (subtle)
                x = (x * levels).round() / levels;

                // Vinyl crackle
                if vinyl > 0.0 {
                    if rng() < vinyl * 0.001 {
                        x += (rng() - 0.3) * vinyl * 0.3;
                    }
                    x += (rng() - 0.5) * vinyl * 0.003;
                }

                ctx.set_output(ch, i, x as f32);
            }
        }
    }
}
