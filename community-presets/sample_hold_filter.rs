// Sample & Hold Filter — random stepped filter modulation.
//
// A bandpass filter whose frequency jumps to random values at a
// clock rate. Creates bubbly, robotic, or glitchy filter textures.

use conjuredsp::*;
setup!();

params! {
    RATE = param(0.5, 30.0).unit("Hz").default(4.0),
    MIN_FREQ = freq().min(100.0).max(2000.0).default(200.0),
    MAX_FREQ = freq().min(2000.0).max(16000.0).default(8000.0),
    RESONANCE = param(0.5, 15.0).unit("Q").default(5.0),
}

static mut RNG_STATE: u32 = 12345;

fn rng() -> f64 {
    unsafe {
        RNG_STATE = RNG_STATE.wrapping_mul(1664525).wrapping_add(1013904223);
        RNG_STATE as f64 / 4294967296.0
    }
}

static mut FILTERS: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];
static mut PHASE: f64 = 0.0;
static mut CURRENT_FREQ: f64 = 1000.0;

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
        let rate = ctx.param(RATE) as f64;
        let min_f = ctx.param(MIN_FREQ) as f64;
        let max_f = ctx.param(MAX_FREQ) as f64;
        let q = ctx.param(RESONANCE) as f64;

        let inc = rate / sr;

        for i in 0..ctx.frames() {
            let old_phase = PHASE;
            PHASE = (PHASE + inc) % 1.0;

            // Trigger new random frequency on phase wrap
            if PHASE < old_phase {
                let log_min = min_f.ln();
                let log_max = max_f.ln();
                CURRENT_FREQ = (log_min + rng() * (log_max - log_min)).exp();
            }

            let coeffs = BiquadCoeffs::bandpass(CURRENT_FREQ, q, sr);
            for c in 0..ctx.channels() {
                FILTERS[c].set_coeffs(coeffs);
                let out = FILTERS[c].process(ctx.input(c, i) as f64) * q;
                ctx.set_output(c, i, out as f32);
            }
        }
    }
}
