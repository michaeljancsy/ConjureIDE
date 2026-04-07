// Comb Filter — metallic resonance effect.

use conjuredsp::*;
setup!();

const MAX_DELAY: usize = 4096;

params! {
    FREQUENCY = freq().min(50.0).max(2000.0).default(200.0),
    FEEDBACK = param(-0.95, 0.95).default(0.7),
    MIX = mix().default(0.5),
}

static mut DELAYS: [DelayLine<MAX_DELAY>; MAX_CH] = [DelayLine::new(); MAX_CH];

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
        let freq_hz = ctx.param(FREQUENCY) as f64;
        let feedback = ctx.param(FEEDBACK);
        let mix = ctx.param(MIX);

        let delay_samples = (sr / freq_hz).max(1.0).min((MAX_DELAY - 1) as f64);

        for i in 0..ctx.frames() {
            for c in 0..ctx.channels() {
                let delayed = DELAYS[c].read(delay_samples);
                DELAYS[c].write(ctx.input(c, i) + delayed * feedback);
                ctx.set_output(c, i, ctx.input(c, i) * (1.0 - mix) + delayed * mix);
            }
        }
    }
}
