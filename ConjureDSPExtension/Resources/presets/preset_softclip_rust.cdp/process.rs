// Soft Clip — tanh waveshaping saturation.
//
// Applies a smooth, warm saturation by passing the signal through a
// hyperbolic tangent function. The drive parameter controls how hard
// the signal is pushed into the nonlinearity. Output is normalized
// so that low-level signals pass through at unity gain.
//
// Params:
//   0 (Drive): Saturation amount — 1.0 to 15.0

use conjuredsp::*;
params! {
    DRIVE = param(1.0, 15.0).default(3.0),
}

fn tanh_f32(x: f32) -> f32 {
    let e2x = (2.0 * x).exp();
    (e2x - 1.0) / (e2x + 1.0)
}

process! { ctx =>
    let drive = ctx.param(DRIVE);
    let norm = 1.0 / tanh_f32(drive);

    for c in 0..ctx.channels() {
        for i in 0..ctx.frames() {
            ctx.set_output(c, i, tanh_f32(drive * ctx.input(c, i)) * norm);
        }
    }
}
