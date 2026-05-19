// Industrial Crush — harsh, aggressive industrial distortion.
//
// Extreme hard clipping, sample rate decimation, and aggressive
// filtering for the harsh, mechanical sound of industrial music.

use conjuredsp::*;
setup!();

params! {
    DESTROY = param(0.0, 1.0).default(0.7),
    GRIND = param(1.0, 20.0).unit("x").default(8.0),
    GATE = param(0.0, 0.2).default(0.05),
    MIX = mix().default(0.8),
}

static mut RNG_STATE: u32 = 12345;

fn rng() -> f64 {
    unsafe {
        RNG_STATE = RNG_STATE.wrapping_mul(1664525).wrapping_add(1013904223);
        RNG_STATE as f64 / 4294967296.0
    }
}

static mut LP: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];
static mut HP: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];
static mut HELD: [f64; MAX_CH] = [0.0; MAX_CH];

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
        let destroy = ctx.param(DESTROY) as f64;
        let grind = ctx.param(GRIND) as f64;
        let gate_thresh = ctx.param(GATE) as f64;
        let wet_mix = ctx.param(MIX) as f64;

        let downsample = {
            let v = 1 + (destroy * 12.0) as usize;
            if v < 1 { 1 } else { v }
        };
        let bits = {
            let v = 16 - (destroy * 10.0) as i32;
            if v < 2 { 2 } else { v }
        };
        let levels = (1 << bits) as f64;

        for ch in 0..ctx.channels() {
            HP[ch].set_coeffs(BiquadCoeffs::highpass(80.0, 1.0, sr));
            LP[ch].set_coeffs(BiquadCoeffs::lowpass(6000.0, 1.0, sr));

            for i in 0..ctx.frames() {
                let mut x = ctx.input(ch, i) as f64;

                // Gate
                if x.abs() < gate_thresh {
                    x = 0.0;
                }

                // Drive
                x *= grind;

                // Hard clip
                if x > 1.0 {
                    x = 1.0;
                } else if x < -1.0 {
                    x = -1.0;
                }

                // Digital destruction
                if destroy > 0.0 {
                    // Bit crush
                    x = (x * levels).round() / levels;

                    // Downsample
                    if i % downsample == 0 {
                        HELD[ch] = x;
                    }
                    x = HELD[ch];

                    // Random noise
                    x += (rng() - 0.5) * destroy * 0.05;
                }

                // Shape
                x = HP[ch].process_sample(x);
                x = LP[ch].process_sample(x);

                ctx.set_output(
                    ch,
                    i,
                    (ctx.input(ch, i) as f64 * (1.0 - wet_mix) + x * wet_mix) as f32,
                );
            }
        }
    }
}
