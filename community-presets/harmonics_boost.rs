// Harmonics Boost — selective harmonic enhancement.

use conjuredsp::*;
setup!();

params! {
    TYPE = choice(&["Even", "Odd", "Both"]),
    AMOUNT = param(0.0, 1.0).default(0.5),
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
        let harm_type = ctx.param(TYPE) as i32;
        let amount = ctx.param(AMOUNT) as f64;
        let wet_mix = ctx.param(MIX) as f64;

        let drive = 1.0 + amount * 8.0;

        for c in 0..ctx.channels() {
            for i in 0..ctx.frames() {
                let x = ctx.input(c, i) as f64;
                let xd = x * drive;

                let harmonics = match harm_type {
                    0 => {
                        // Even harmonics
                        let y = xd.tanh() + 0.3 * xd.tanh().powi(2) * if xd >= 0.0 { 1.0 } else { -1.0 };
                        y - x
                    }
                    1 => {
                        // Odd harmonics
                        xd.tanh() - x
                    }
                    _ => {
                        // Both
                        (xd * 1.5).tanh() * 0.7 - x
                    }
                };

                ctx.set_output(c, i, (x + harmonics * wet_mix) as f32);
            }
        }
    }
}
