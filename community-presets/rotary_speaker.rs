// Rotary Speaker — Leslie cabinet simulation.
//
// Models the iconic Leslie 122: a spinning horn (treble) and drum
// (bass) create doppler pitch shift, amplitude modulation, and
// phase modulation. The horn spins faster than the drum.

use conjuredsp::*;
setup!();

params! {
    SPEED = choice(&["Slow", "Fast"]).default(0.0),
    DEPTH = param(0.0, 1.0).default(0.7),
    MIX = mix().default(0.8),
}

static mut DELAYS: [DelayLine<512>; MAX_CH] = [DelayLine::new(); MAX_CH];
static mut HORN_PHASE: f64 = 0.0;
static mut DRUM_PHASE: f64 = 0.0;
static mut HORN_SPEED: f64 = 0.0;
static mut DRUM_SPEED: f64 = 0.0;

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
        let speed_mode = ctx.param(SPEED) as i32;
        let depth = ctx.param(DEPTH) as f64;
        let wet_mix = ctx.param(MIX) as f64;

        let target_horn = if speed_mode == 1 { 6.0 } else { 0.8 };
        let target_drum = if speed_mode == 1 { 4.5 } else { 0.6 };
        let accel = 0.5 / sr;

        let two_pi = 2.0 * core::f64::consts::PI;

        for i in 0..ctx.frames() {
            HORN_SPEED += (target_horn - HORN_SPEED) * accel * 100.0;
            DRUM_SPEED += (target_drum - DRUM_SPEED) * accel * 100.0;

            let horn_mod = (two_pi * HORN_PHASE).sin() * depth * 3.0;
            let drum_mod = (two_pi * DRUM_PHASE).sin() * depth * 1.5;

            let horn_amp = 0.7 + 0.3 * (two_pi * HORN_PHASE).cos();
            let drum_amp = 0.8 + 0.2 * (two_pi * DRUM_PHASE).cos();

            for c in 0..ctx.channels() {
                let x = ctx.input(c, i) as f64;
                DELAYS[c].write(x);

                let modulation = horn_mod + drum_mod + 5.0;
                let delayed = DELAYS[c].read(if modulation > 1.0 { modulation } else { 1.0 });

                let wet = delayed * horn_amp * drum_amp;

                ctx.set_output(c, i, (x * (1.0 - wet_mix) + wet * wet_mix) as f32);
            }

            HORN_PHASE = (HORN_PHASE + HORN_SPEED / sr) % 1.0;
            DRUM_PHASE = (DRUM_PHASE + DRUM_SPEED / sr) % 1.0;
        }
    }
}
