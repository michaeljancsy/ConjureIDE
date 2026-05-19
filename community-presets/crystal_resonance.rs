// Crystal Resonance -- high-Q harmonic resonator bank.
//
// Multiple ultra-sharp bandpass filters tuned to harmonic
// intervals of a fundamental pitch. Input audio excites the
// resonators, producing bell-like, crystalline ringing.

use conjuredsp::*;
setup!();

params! {
    PITCH = freq().min(200.0).max(8000.0).default(1000.0),
    HARMONICS = param(1.0, 8.0).default(4.0),
    RESONANCE = param(5.0, 30.0).unit("Q").default(15.0),
    MIX = mix().default(0.5),
}

const MAX_HARMONICS: usize = 8;

static mut FILTERS: [[Biquad; MAX_HARMONICS]; MAX_CH] =
    [[Biquad::new(); MAX_HARMONICS]; MAX_CH];

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
        let n_harmonics = (ctx.param(HARMONICS) as f64) as usize;
        let q = ctx.param(RESONANCE) as f64;
        let wet_mix = ctx.param(MIX) as f64;

        for ch in 0..ctx.channels() {
            for i in 0..ctx.frames() {
                let x = ctx.input(ch, i) as f64;
                let mut wet = 0.0_f64;

                for h in 0..n_harmonics {
                    let harmonic_freq = pitch_hz * (h + 1) as f64;
                    if harmonic_freq >= sr * 0.45 {
                        break;
                    }

                    let coeffs =
                        BiquadCoeffs::bandpass(harmonic_freq, q, sr);
                    FILTERS[ch][h].set_coeffs(coeffs);

                    // Higher harmonics get progressively quieter
                    let level = 1.0 / (h + 1) as f64;
                    wet += FILTERS[ch][h].process_sample(x as f32)
                        as f64
                        * q
                        * level;
                }

                wet /= n_harmonics.max(1) as f64;

                let dry = x;
                ctx.set_output(
                    ch,
                    i,
                    (dry * (1.0 - wet_mix) + wet * wet_mix) as f32,
                );
            }
        }
    }
}
