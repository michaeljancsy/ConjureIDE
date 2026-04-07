// Barber Pole Phaser — infinite ascending/descending phase sweep.
//
// Uses multiple staggered allpass filter stages with offset phases
// to create the auditory illusion of an endlessly rising or falling
// phaser sweep (Shepard tone principle applied to phase shifting).

use conjuredsp::*;
setup!();

params! {
    DIRECTION = choice(&["Up", "Down"]).default(0.0),
    RATE = param(0.05, 2.0).unit("Hz").default(0.2),
    DEPTH = param(0.0, 1.0).default(0.7),
    MIX = mix().default(0.7),
}

const NUM_STAGES: usize = 6;
static mut PHASE: f64 = 0.0;
static mut AP_STAGES: [[Biquad; NUM_STAGES]; MAX_CH] = [[Biquad::new(); NUM_STAGES]; MAX_CH];

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
        let direction = ctx.param(DIRECTION) as i32;
        let rate = ctx.param(RATE) as f64;
        let depth = ctx.param(DEPTH) as f64;
        let wet_mix = ctx.param(MIX) as f64;

        for i in 0..ctx.frames() {
            let phase = if direction == 0 { PHASE } else { 1.0 - PHASE };

            for c in 0..ctx.channels() {
                let dry = ctx.input(c, i) as f64;
                let mut x = dry;

                for s in 0..NUM_STAGES {
                    let stage_phase = (phase + s as f64 / NUM_STAGES as f64) % 1.0;

                    // Map phase to frequency logarithmically
                    let mut sweep_freq = 100.0 * (2.0_f64).powf(stage_phase * depth * 7.0);
                    if sweep_freq > sr * 0.45 {
                        sweep_freq = sr * 0.45;
                    }

                    let coeffs = BiquadCoeffs::allpass(sweep_freq, 1.0, sr);
                    AP_STAGES[c][s].set_coeffs(coeffs);
                    x = AP_STAGES[c][s].process(x);
                }

                let wet = x;
                ctx.set_output(c, i, (dry * (1.0 - wet_mix) + wet * wet_mix) as f32);
            }

            PHASE = (PHASE + rate / sr) % 1.0;
        }
    }
}
