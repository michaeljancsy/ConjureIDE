// Spring Reverb — guitar amp spring tank simulation.
//
// Models the characteristic "boing" and splash of a spring reverb
// tank. Uses comb filtering with allpass dispersion to create the
// metallic, twangy reverb character.

use conjuredsp::*;
setup!();

params! {
    DWELL = param(0.0, 1.0).default(0.5),
    TONE = param(0.0, 1.0).default(0.6),
    DRIP = param(0.0, 1.0).default(0.4),
    MIX = mix().default(0.3),
}

const SPRING_TIMES: [usize; 3] = [467, 631, 853];

static mut DELAYS: [[DelayLine<2048>; 3]; MAX_CH] = [[DelayLine::new(); 3]; MAX_CH];
static mut AP: [DelayLine<512>; MAX_CH] = [DelayLine::new(); MAX_CH];
static mut LP: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];
static mut HP: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];
static mut DRIP_ENV: f64 = 0.0;
static mut RNG_STATE: u32 = 12345;

fn rng() -> f64 {
    unsafe {
        RNG_STATE = RNG_STATE.wrapping_mul(1664525).wrapping_add(1013904223);
        RNG_STATE as f64 / 4294967296.0
    }
}

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
        let dwell = ctx.param(DWELL) as f64;
        let tone = ctx.param(TONE) as f64;
        let drip = ctx.param(DRIP) as f64;
        let wet_mix = ctx.param(MIX) as f64;

        let feedback = 0.3 + dwell * 0.55;
        let lp_freq = 2000.0 + tone * 6000.0;

        for ch in 0..ctx.channels() {
            LP[ch].set_coeffs(BiquadCoeffs::lowpass(lp_freq, 0.8, sr));
            HP[ch].set_coeffs(BiquadCoeffs::highpass(150.0, 0.7, sr));

            for i in 0..ctx.frames() {
                let x = ctx.input(ch, i) as f64;

                // Drip detection -- spring crash on transients
                let level = x.abs();
                if level > DRIP_ENV {
                    DRIP_ENV = level;
                } else {
                    DRIP_ENV *= 0.9995;
                }

                let drip_amount = (DRIP_ENV - 0.1).max(0.0) * drip * 5.0;
                let drip_noise = (rng() - 0.5) * drip_amount * 0.3;

                // Comb filter network (spring resonances)
                let mut wet = 0.0_f64;
                for s in 0..3 {
                    let delayed = DELAYS[ch][s].tap(SPRING_TIMES[s]) as f64;
                    DELAYS[ch][s]
                        .write((x + delayed * feedback + drip_noise) as f32);
                    wet += delayed;
                }

                wet /= 3.0;

                // Allpass dispersion (spring is dispersive)
                let ap_out = AP[ch].tap(173) as f64;
                AP[ch].write((wet - 0.4 * ap_out) as f32);
                wet = ap_out + 0.4 * wet;

                // Tone shaping
                wet = LP[ch].process_sample(wet);
                wet = HP[ch].process_sample(wet);

                let dry = ctx.input(ch, i) as f64;
                ctx.set_output(
                    ch,
                    i,
                    (dry * (1.0 - wet_mix) + wet * wet_mix) as f32,
                );
            }
        }
    }
}
