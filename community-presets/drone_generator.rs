// Drone Generator -- create sustained drones from any input.
//
// Feeds input into a tuned resonator with very high feedback,
// causing the resonant pitch to build up and sustain. Short
// percussive inputs create pitched drones that evolve over time.

use conjuredsp::*;
setup!();

params! {
    PITCH = freq().min(30.0).max(500.0).default(110.0),
    SUSTAIN = param(0.95, 1.0).default(0.995),
    TONE = param(0.0, 1.0).default(0.4),
    MIX = mix().default(0.5),
}

static mut DELAYS: [DelayLine<8192>; MAX_CH] = [DelayLine::new(); MAX_CH];
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
        let pitch_hz = ctx.param(PITCH) as f64;
        let sustain = ctx.param(SUSTAIN) as f64;
        let tone = ctx.param(TONE) as f64;
        let wet_mix = ctx.param(MIX) as f64;

        let delay_samples = (sr / pitch_hz).max(2.0).min(8191.0);
        let lp_freq = 300.0 + tone * 5000.0;

        for ch in 0..ctx.channels() {
            LP[ch].set_coeffs(BiquadCoeffs::lowpass(lp_freq, 0.7, sr));

            for i in 0..ctx.frames() {
                let delayed = DELAYS[ch].read(delay_samples) as f64;
                let delayed = LP[ch].process_sample(delayed as f32) as f64;
                let delayed = delayed.tanh();

                let inp = ctx.input(ch, i) as f64;
                DELAYS[ch].write((inp * 0.2 + delayed * sustain) as f32);

                ctx.set_output(
                    ch,
                    i,
                    (inp * (1.0 - wet_mix) + delayed * wet_mix) as f32,
                );
            }
        }
    }
}
