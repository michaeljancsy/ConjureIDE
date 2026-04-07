// Dotted Eighth Delay — The Edge's signature rhythmic delay.
//
// BPM-synced delay at a dotted eighth note (3/16), creating the
// distinctive galloping rhythm that defines U2's guitar sound.

use conjuredsp::*;
setup!();

params! {
    FEEDBACK = param(0.0, 0.8).default(0.35),
    TONE = param(0.0, 1.0).default(0.6),
    MIX = mix().default(0.45),
}

const MAX_DELAY: usize = 192000;

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
        let feedback = ctx.param(FEEDBACK) as f64;
        let tone = ctx.param(TONE) as f64;
        let wet_mix = ctx.param(MIX) as f64;
        let tempo = TRANSPORT_BUF[T_TEMPO] as f64;

        // Dotted eighth = 3/16 of a whole note = 3/4 of a beat
        let mut delay_samples = if tempo > 0.0 {
            let beats = 0.75; // dotted eighth
            let delay_seconds = beats * 60.0 / tempo;
            delay_seconds * sr
        } else {
            0.375 * sr // fallback at 120 BPM
        };

        if delay_samples < 1.0 {
            delay_samples = 1.0;
        }
        if delay_samples > (MAX_DELAY - 1) as f64 {
            delay_samples = (MAX_DELAY - 1) as f64;
        }

        let lp_freq = 3000.0 + tone * 9000.0;

        for ch in 0..ctx.channels() {
            LP[ch].set_coeffs(BiquadCoeffs::lowpass(lp_freq, 0.7, sr));

            for i in 0..ctx.frames() {
                let mut delayed = DELAYS[ch].read(delay_samples) as f64;
                delayed = LP[ch].process_sample(delayed);

                DELAYS[ch].write((ctx.input(ch, i) as f64 + delayed * feedback) as f32);

                ctx.set_output(
                    ch,
                    i,
                    (ctx.input(ch, i) as f64 * (1.0 - wet_mix) + delayed * wet_mix) as f32,
                );
            }
        }
    }
}
