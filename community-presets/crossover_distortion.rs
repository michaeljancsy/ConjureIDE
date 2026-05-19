// Crossover Distortion — Class B amplifier artifact.

use conjuredsp::*;
setup!();

params! {
    DEADZONE = param(0.01, 0.5).default(0.1),
    DRIVE = param(1.0, 10.0).unit("x").default(3.0),
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
        let deadzone = ctx.param(DEADZONE) as f64;
        let drive = ctx.param(DRIVE) as f64;
        let wet_mix = ctx.param(MIX) as f64;

        for c in 0..ctx.channels() {
            for i in 0..ctx.frames() {
                let x = ctx.input(c, i) as f64 * drive;

                let y = if x > deadzone {
                    x - deadzone
                } else if x < -deadzone {
                    x + deadzone
                } else {
                    0.0
                };

                let y = y.tanh();

                ctx.set_output(c, i, (ctx.input(c, i) as f64 * (1.0 - wet_mix) + y * wet_mix) as f32);
            }
        }
    }
}
