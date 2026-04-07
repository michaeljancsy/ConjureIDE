// Slapback — classic rockabilly/surf single echo.
//
// A single short echo with no feedback, creating the characteristic
// "slap" heard on 1950s rockabilly vocals and guitar.

use conjuredsp::*;
setup!();

params! {
    TIME = time_ms().min(30.0).max(120.0).default(75.0),
    MIX = mix().default(0.4),
}

const MAX_DELAY: usize = 12000;

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
        let delay_ms = ctx.param(TIME) as f64;
        let wet_mix = ctx.param(MIX) as f64;

        let mut delay_samples = (delay_ms * 0.001 * sr) as usize;
        if delay_samples < 1 {
            delay_samples = 1;
        }
        if delay_samples > MAX_DELAY - 1 {
            delay_samples = MAX_DELAY - 1;
        }

        for i in 0..ctx.frames() {
            for ch in 0..ctx.channels() {
                DELAYS[ch].write(ctx.input(ch, i));
                let delayed = DELAYS[ch].tap(delay_samples) as f64;
                ctx.set_output(ch, i, (ctx.input(ch, i) as f64 + delayed * wet_mix) as f32);
            }
        }
    }
}
