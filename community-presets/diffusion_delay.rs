// Diffusion Delay — smeared, reverb-like echoes.
//
// Passes delay repeats through a chain of allpass diffusers that
// smear each echo into a wash. At low diffusion, echoes are
// distinct; at high diffusion, echoes blur into reverb-like tails.

use conjuredsp::*;
setup!();

params! {
    TIME = time_ms().min(50.0).max(500.0).default(200.0),
    DIFFUSION = param(0.0, 1.0).default(0.7),
    FEEDBACK = param(0.0, 0.9).default(0.4),
    DAMPING = param(0.0, 1.0).default(0.3),
    MIX = mix().default(0.5),
}

const MAX_DELAY: usize = 48000;

// Allpass delay times (prime numbers for maximal diffusion)
const AP_TIMES: [usize; 4] = [113, 337, 571, 907];

static mut MAIN_DELAYS: [DelayLine<MAX_DELAY>; MAX_CH] = [DelayLine::new(); MAX_CH];
static mut AP_DELAYS: [[DelayLine<1024>; 4]; MAX_CH] = [[DelayLine::new(); 4]; MAX_CH];
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
        let delay_ms = ctx.param(TIME) as f64;
        let diffusion = ctx.param(DIFFUSION) as f64;
        let feedback = ctx.param(FEEDBACK) as f64;
        let damping = ctx.param(DAMPING) as f64;
        let wet_mix = ctx.param(MIX) as f64;

        let mut delay_samples = delay_ms * 0.001 * sr;
        if delay_samples < 1.0 {
            delay_samples = 1.0;
        }

        let lp_freq = 14000.0 - damping * 10000.0;
        let ap_coeff = diffusion * 0.7;

        for ch in 0..ctx.channels() {
            LP[ch].set_coeffs(BiquadCoeffs::lowpass(lp_freq, 0.7, sr));

            for i in 0..ctx.frames() {
                let delayed = MAIN_DELAYS[ch].read(delay_samples) as f64;

                // Diffusion: cascade of allpass filters
                let mut y = delayed;
                for ap_idx in 0..4 {
                    let ap_out = AP_DELAYS[ch][ap_idx].tap(AP_TIMES[ap_idx]) as f64;
                    let ap_in = y - ap_coeff * ap_out;
                    AP_DELAYS[ch][ap_idx].write(ap_in as f32);
                    y = ap_out + ap_coeff * ap_in;
                }

                // Damping
                y = LP[ch].process_sample(y);

                MAIN_DELAYS[ch].write((ctx.input(ch, i) as f64 + y * feedback) as f32);

                ctx.set_output(
                    ch,
                    i,
                    (ctx.input(ch, i) as f64 * (1.0 - wet_mix) + y * wet_mix) as f32,
                );
            }
        }
    }
}
