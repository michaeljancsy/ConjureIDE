// Tube Warmth — gentle tube-style saturation.
//
// Models the soft compression and even-harmonic generation of a vacuum
// tube amplifier. A post-saturation tone control rolls off harsh highs.

use conjuredsp::*;
setup!();

params! {
    DRIVE = param(1.0, 10.0).unit("x").default(2.0),
    TONE = param(0.0, 1.0).default(0.5),
    MIX = mix().default(0.7),
}

static mut LP_STATE: [f64; MAX_CH] = [0.0; MAX_CH];

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
        let drive = ctx.param(DRIVE) as f64;
        let tone = ctx.param(TONE) as f64;
        let wet_mix = ctx.param(MIX) as f64;

        let cutoff = 800.0 + tone * 15200.0;
        let rc = 1.0 / (2.0 * core::f64::consts::PI * cutoff);
        let dt = 1.0 / sr;
        let alpha = dt / (rc + dt);

        for c in 0..ctx.channels() {
            let mut lp = LP_STATE[c];

            for i in 0..ctx.frames() {
                let x = ctx.input(c, i) as f64 * drive;

                let y = if x >= 0.0 {
                    x.tanh()
                } else {
                    (x * 0.8).tanh() * 1.25
                };

                lp += alpha * (y - lp);

                ctx.set_output(c, i, (ctx.input(c, i) as f64 * (1.0 - wet_mix) + lp * wet_mix) as f32);
            }

            LP_STATE[c] = lp;
        }
    }
}
