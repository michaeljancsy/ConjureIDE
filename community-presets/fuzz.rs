// Fuzz — classic 60s germanium fuzz pedal.
//
// Heavy clipping with a sputtery, gated character at low input levels.

use conjuredsp::*;
setup!();

params! {
    FUZZ = param(1.0, 50.0).unit("x").default(15.0),
    TONE = freq().min(500.0).max(8000.0).default(2000.0),
    GATE = param(0.0, 0.1).default(0.01),
    LEVEL = param(0.0, 1.0).default(0.7),
}

static mut LP: [f64; MAX_CH] = [0.0; MAX_CH];

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
        let fuzz = ctx.param(FUZZ) as f64;
        let tone_hz = ctx.param(TONE) as f64;
        let gate_thresh = ctx.param(GATE) as f64;
        let level = ctx.param(LEVEL) as f64;

        let rc = 1.0 / (2.0 * core::f64::consts::PI * tone_hz);
        let dt = 1.0 / sr;
        let alpha = dt / (rc + dt);

        for c in 0..ctx.channels() {
            let mut lp = LP[c];

            for i in 0..ctx.frames() {
                let mut x = ctx.input(c, i) as f64;

                if x.abs() < gate_thresh {
                    x = 0.0;
                }

                x *= fuzz;
                let y = if x > 0.0 {
                    1.0 - (-x).exp()
                } else {
                    -(1.0 - (x * 1.5).exp())
                };

                lp += alpha * (y - lp);

                ctx.set_output(c, i, (lp * level) as f32);
            }

            LP[c] = lp;
        }
    }
}
