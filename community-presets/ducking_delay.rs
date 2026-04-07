// Ducking Delay — delay that hides under the dry signal.
//
// The delay output is automatically reduced when the input is loud
// and swells up during quiet moments. This keeps delays from
// cluttering the mix during busy passages.

use conjuredsp::*;
setup!();

params! {
    TIME = time_ms().min(50.0).max(800.0).default(350.0),
    FEEDBACK = param(0.0, 0.9).default(0.4),
    DUCK = param(0.0, 1.0).default(0.7),
    RELEASE = time_ms().min(50.0).max(1000.0).default(200.0),
    MIX = mix().default(0.7),
}

const MAX_DELAY: usize = 96000;

static mut DELAYS: [DelayLine<MAX_DELAY>; MAX_CH] = [DelayLine::new(); MAX_CH];
static mut ENVELOPE: f64 = 0.0;

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
        let feedback = ctx.param(FEEDBACK) as f64;
        let duck = ctx.param(DUCK) as f64;
        let release_ms = ctx.param(RELEASE) as f64;
        let wet_mix = ctx.param(MIX) as f64;

        let mut delay_samples = delay_ms * 0.001 * sr;
        if delay_samples < 1.0 {
            delay_samples = 1.0;
        }

        let attack_coeff = smooth_coeff(1.0, sr);
        let release_coeff = smooth_coeff(release_ms, sr);

        for i in 0..ctx.frames() {
            // Peak detect across channels
            let mut peak = 0.0_f64;
            for ch in 0..ctx.channels() {
                let v = (ctx.input(ch, i) as f64).abs();
                if v > peak {
                    peak = v;
                }
            }

            // Envelope follower
            if peak > ENVELOPE {
                ENVELOPE = attack_coeff * ENVELOPE + (1.0 - attack_coeff) * peak;
            } else {
                ENVELOPE = release_coeff * ENVELOPE + (1.0 - release_coeff) * peak;
            }

            // Duck factor: higher envelope = lower wet level
            let mut duck_gain = 1.0 - ENVELOPE * duck * 10.0;
            if duck_gain < 0.0 {
                duck_gain = 0.0;
            }

            for ch in 0..ctx.channels() {
                let delayed = DELAYS[ch].read(delay_samples) as f64;
                DELAYS[ch].write((ctx.input(ch, i) as f64 + delayed * feedback) as f32);

                ctx.set_output(
                    ch,
                    i,
                    (ctx.input(ch, i) as f64 + delayed * wet_mix * duck_gain) as f32,
                );
            }
        }
    }
}
