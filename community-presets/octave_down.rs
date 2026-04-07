// Octave Down — sub-octave generator (Boss OC-2 style).

use conjuredsp::*;
setup!();

params! {
    OCTAVE1 = param(0.0, 1.0).default(0.7),
    OCTAVE2 = param(0.0, 1.0).default(0.3),
    TONE = param(0.0, 1.0).default(0.5),
    MIX = mix().default(0.5),
}

static mut PREV_SIGN: f64 = 1.0;
static mut LP: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];
static mut SQUARE1: f64 = 1.0;
static mut SQUARE2: f64 = 1.0;
static mut TOGGLE: bool = false;

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
        let oct1_level = ctx.param(OCTAVE1) as f64;
        let oct2_level = ctx.param(OCTAVE2) as f64;
        let tone = ctx.param(TONE) as f64;
        let wet_mix = ctx.param(MIX) as f64;

        let lp_freq = 200.0 + tone * 2000.0;

        for c in 0..ctx.channels() {
            LP[c].set_coeffs(BiquadCoeffs::lowpass(lp_freq, 0.7, sr));

            for i in 0..ctx.frames() {
                let x = ctx.input(c, i) as f64;

                if c == 0 {
                    let current_sign = if x >= 0.0 { 1.0 } else { -1.0 };
                    if current_sign != PREV_SIGN {
                        SQUARE1 = -SQUARE1;
                        TOGGLE = !TOGGLE;
                        if TOGGLE {
                            SQUARE2 = -SQUARE2;
                        }
                        PREV_SIGN = current_sign;
                    }
                }

                let sub = SQUARE1 * oct1_level + SQUARE2 * oct2_level;
                let env = x.abs();
                let sub = sub * env;

                let sub = LP[c].process_sample(sub);

                ctx.set_output(c, i, (x * (1.0 - wet_mix) + (x + sub) * wet_mix) as f32);
            }
        }
    }
}
