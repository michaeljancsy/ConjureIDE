// Ladder Filter — Moog-style 24 dB/octave resonant lowpass.

use conjuredsp::*;
setup!();

params! {
    CUTOFF = freq().default(1000.0),
    RESONANCE = param(0.0, 4.0).default(1.0),
    DRIVE = param(1.0, 5.0).unit("x").default(1.0),
}

static mut STATE: [[f64; 4]; MAX_CH] = [[0.0; 4]; MAX_CH];

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
        let cutoff_hz = ctx.param(CUTOFF) as f64;
        let resonance = ctx.param(RESONANCE) as f64;
        let drive = ctx.param(DRIVE) as f64;

        let f = (core::f64::consts::PI * cutoff_hz.min(sr * 0.45) / sr).sin() * 2.0;

        for c in 0..ctx.channels() {
            let s = &mut STATE[c];

            for i in 0..ctx.frames() {
                let mut x = ctx.input(c, i) as f64 * drive;

                x -= resonance * s[3];
                x = x.tanh();

                s[0] += f * (x - s[0]);
                s[1] += f * (s[0] - s[1]);
                s[2] += f * (s[1] - s[2]);
                s[3] += f * (s[2] - s[3]);

                ctx.set_output(c, i, s[3] as f32);
            }
        }
    }
}
