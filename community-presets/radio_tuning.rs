// AM Radio — vintage radio / broadcast simulation.
//
// Simulates the narrow bandwidth, distortion, and noise of an
// AM radio transmission.

use conjuredsp::*;
setup!();

params! {
    STATIC = param(0.0, 1.0).default(0.3),
    BANDWIDTH = param(0.0, 1.0).default(0.5),
    TONE = param(0.0, 1.0).default(0.3),
    MIX = mix().default(1.0),
}

static mut BP: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];
static mut LP_FILT: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];
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
        let static_amt = ctx.param(STATIC) as f64;
        let bandwidth = ctx.param(BANDWIDTH) as f64;
        let tone = ctx.param(TONE) as f64;
        let wet_mix = ctx.param(MIX) as f64;

        // Radio bandwidth: 200-5000 Hz range
        let center = 1200.0 + tone * 1500.0;
        let q = 0.5 + (1.0 - bandwidth) * 5.0;

        for ch in 0..ctx.channels() {
            BP[ch].set_coeffs(BiquadCoeffs::bandpass(center, q, sr));
            LP_FILT[ch].set_coeffs(BiquadCoeffs::lowpass(3000.0 + bandwidth * 5000.0, 0.7, sr));

            for i in 0..ctx.frames() {
                let x = ctx.input(ch, i) as f64;

                // Bandpass to radio spectrum
                let mut y = BP[ch].process_sample(x) * q * 0.5;
                y = LP_FILT[ch].process_sample(y);

                // AM transmitter compression
                y = (y * 3.0).tanh() * 0.5;

                // Static noise
                y += (rng() - 0.5) * static_amt * 0.1;

                ctx.set_output(ch, i, (x * (1.0 - wet_mix) + y * wet_mix) as f32);
            }
        }
    }
}
