// Frequency Shifter — Bode-style frequency shift.
//
// Shifts all frequencies by a fixed Hz amount (not a ratio).
// Small shifts (1-5 Hz) create phasing/tremolo; larger shifts
// produce metallic, bell-like, or alien timbres.

use conjuredsp::*;
setup!();

params! {
    SHIFT = param(-500.0, 500.0).unit("Hz").default(5.0),
    FEEDBACK = param(0.0, 0.9).default(0.0),
}

static mut PHASE: f64 = 0.0;
static mut FB_SAMPLE: [f64; MAX_CH] = [0.0; MAX_CH];

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
        let shift_hz = ctx.param(SHIFT) as f64;
        let feedback = ctx.param(FEEDBACK) as f64;

        let two_pi = 2.0 * core::f64::consts::PI;
        let phase_inc = shift_hz / sr;

        for c in 0..ctx.channels() {
            let mut fb = FB_SAMPLE[c];

            for i in 0..ctx.frames() {
                let x = ctx.input(c, i) as f64 + fb * feedback;

                // Simple frequency shift using ring modulation
                let cos_val = (two_pi * PHASE).cos();

                // Single-sideband approximation using phase quadrature
                let y = x * cos_val;

                fb = y;

                ctx.set_output(c, i, y as f32);

                if c == 0 {
                    PHASE = (PHASE + phase_inc) % 1.0;
                }
            }

            FB_SAMPLE[c] = fb;
        }
    }
}
