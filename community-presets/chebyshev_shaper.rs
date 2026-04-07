// Chebyshev Waveshaper — harmonic-specific distortion.

use conjuredsp::*;
setup!();

params! {
    HARMONIC = choice(&["2nd", "3rd", "4th", "5th"]),
    DRIVE = param(0.0, 1.0).default(0.5),
    MIX = mix().default(0.5),
}

#[no_mangle]
pub extern "C" fn process(
    input: *const f32,
    output: *mut f32,
    channels: i32,
    frame_count: i32,
    sample_rate: f32,
) {
    let ctx = ctx(input, output, channels, frame_count, sample_rate);

    unsafe {
        let harm_idx = ctx.param(HARMONIC) as i32;
        let drive = ctx.param(DRIVE) as f64;
        let wet_mix = ctx.param(MIX) as f64;

        for c in 0..ctx.channels() {
            for i in 0..ctx.frames() {
                let x = ctx.input(c, i) as f64;

                let xc = x.max(-1.0).min(1.0);

                let shaped = match harm_idx {
                    0 => 2.0 * xc * xc - 1.0,               // T2
                    1 => 4.0 * xc * xc * xc - 3.0 * xc,     // T3
                    2 => {                                     // T4
                        let x2 = xc * xc;
                        8.0 * x2 * x2 - 8.0 * x2 + 1.0
                    }
                    _ => {                                     // T5
                        let x2 = xc * xc;
                        let x3 = x2 * xc;
                        16.0 * x2 * x3 - 20.0 * x3 + 5.0 * xc
                    }
                };

                let y = x + drive * (shaped - x);

                ctx.set_output(c, i, (ctx.input(c, i) as f64 * (1.0 - wet_mix) + y * wet_mix) as f32);
            }
        }
    }
}
