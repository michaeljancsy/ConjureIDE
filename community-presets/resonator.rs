// Resonator — tuned resonant body simulation.

use conjuredsp::*;
setup!();

const MAX_DELAY: usize = 4096;

params! {
    NOTE = freq().min(50.0).max(2000.0).default(220.0),
    DECAY = param(0.1, 5.0).unit("s").default(1.0),
    BRIGHTNESS = param(0.0, 1.0).default(0.5),
    MIX = mix().default(0.5),
}

static mut DELAYS: [DelayLine<MAX_DELAY>; MAX_CH] = [DelayLine::new(); MAX_CH];
static mut LP: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];

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
        let note_hz = ctx.param(NOTE) as f64;
        let decay_s = ctx.param(DECAY) as f64;
        let brightness = ctx.param(BRIGHTNESS) as f64;
        let wet_mix = ctx.param(MIX) as f64;

        let delay_samples = (sr / note_hz).max(2.0).min((MAX_DELAY - 1) as f64);

        let feedback = if decay_s > 0.0 {
            10.0_f64.powf(-3.0 * delay_samples / (decay_s * sr))
        } else {
            0.0
        };

        let lp_freq = 1000.0 + brightness * 10000.0;

        for c in 0..ctx.channels() {
            LP[c].set_coeffs(BiquadCoeffs::lowpass(lp_freq, 0.7, sr));

            for i in 0..ctx.frames() {
                let delayed = DELAYS[c].read(delay_samples);
                let filtered = LP[c].process_sample(delayed as f64);
                DELAYS[c].write(ctx.input(c, i) + filtered as f32 * feedback as f32);
                ctx.set_output(c, i, (ctx.input(c, i) as f64 * (1.0 - wet_mix) + delayed as f64 * wet_mix) as f32);
            }
        }
    }
}
