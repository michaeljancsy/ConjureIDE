// Vibrato — pure pitch modulation.
//
// Unlike chorus (which mixes dry and wet), vibrato modulates pitch
// without any dry signal. A sine LFO varies the read position in a
// delay line, creating periodic pitch variation.

use conjuredsp::*;
setup!();

params! {
    RATE = param(0.5, 14.0).unit("Hz").default(5.0),
    DEPTH = param(0.0, 1.0).default(0.5),
}

static mut DELAYS: [DelayLine<1024>; MAX_CH] = [DelayLine::new(); MAX_CH];
static mut PHASE: f64 = 0.0;

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
        let rate = ctx.param(RATE) as f64;
        let depth = ctx.param(DEPTH) as f64;

        let two_pi = 2.0 * core::f64::consts::PI;
        let max_depth_samples = depth * 10.0;
        let center_delay = 15.0;

        for i in 0..ctx.frames() {
            let modulation = (two_pi * PHASE).sin() * max_depth_samples;
            let delay_samples = center_delay + modulation;
            let delay_clamped = if delay_samples > 1.0 { delay_samples } else { 1.0 };

            for c in 0..ctx.channels() {
                DELAYS[c].write(ctx.input(c, i) as f64);
                ctx.set_output(c, i, DELAYS[c].read_cubic(delay_clamped) as f32);
            }

            PHASE = (PHASE + rate / sr) % 1.0;
        }
    }
}
