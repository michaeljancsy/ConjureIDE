// Hard Clip — hard clipping distortion.
//
// Amplifies the signal by the drive amount, then clips any values
// exceeding +/-1.0. Produces a harsh, buzzy distortion with odd harmonics.
// Higher drive values push more of the signal into clipping.
//
// Controls:
//   0 (Drive): Amplification factor — 1.0 to 20.0

use conjuredsp::*;

params! {
    DRIVE = param(1.0, 20.0).default(5.0),
}

process! { ctx =>
    let drive = ctx.param(DRIVE);

    for c in 0..ctx.channels() {
        for i in 0..ctx.frames() {
            let driven = drive * ctx.input(c, i);
            let clipped = if driven > 1.0 {
                1.0
            } else if driven < -1.0 {
                -1.0
            } else {
                driven
            };
            ctx.set_output(c, i, clipped);
        }
    }
}
