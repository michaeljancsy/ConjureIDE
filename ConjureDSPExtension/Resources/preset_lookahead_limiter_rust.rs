// Lookahead Limiter — transparent brick-wall limiter.
//
// Delays the audio signal by LOOKAHEAD samples while analyzing peaks
// from the non-delayed input. By the time a transient arrives through
// the delay line, the gain is already reduced — enabling transparent
// limiting without the artifacts of a fast attack time.
//
// Params:
//   0 (Threshold): Ceiling level — -24 to 0 dB
//   1 (Release):   Release time — 10 to 500 ms

use conjuredsp::*;
setup!();

const LOOKAHEAD: usize = 256;

latency!(LOOKAHEAD);

params! {
    THRESHOLD = db().min(-24.0).max(0.0).default(-3.0),
    RELEASE = time_ms().min(10.0).max(500.0).default(100.0),
}

// Persistent state
// +1 to match Python's DelayLine(LATENCY + 1) sizing
static mut DELAYS: [DelayLine<257>; 2] = [DelayLine::new(); 2];
static mut GAIN: f64 = 1.0;

#[no_mangle]
pub extern "C" fn process(
    input: *const f32,
    output: *mut f32,
    channels: i32,
    frame_count: i32,
    sample_rate: f32,
) {
    let ctx = ctx(input, output, channels, frame_count, sample_rate);
    let sr = ctx.sample_rate() as f64;

    unsafe {
        let threshold_db = ctx.param(THRESHOLD) as f64;
        let release_ms = ctx.param(RELEASE) as f64;

        let threshold = db_to_gain(threshold_db);
        let release_coeff = smooth_coeff(release_ms, sr);

        let mut g = GAIN;

        for i in 0..ctx.frames() {
            // Peak detect from raw (non-delayed) input
            let mut peak: f64 = 0.0;
            for c in 0..ctx.channels() {
                let abs_val = (ctx.input(c, i) as f64).abs();
                if abs_val > peak {
                    peak = abs_val;
                }
            }

            // Compute target gain
            let target = if peak > threshold {
                threshold / peak
            } else {
                1.0
            };

            // Instant attack (snap to lower gain), smooth release
            if target < g {
                g = target;
            } else {
                g = release_coeff * g + (1.0 - release_coeff) * target;
            }

            // Truncate to f32 to match Python's np.float32 truncation
            let gain: f32 = g as f32;

            for c in 0..ctx.channels() {
                DELAYS[c].write(ctx.input(c, i));
                let delayed = DELAYS[c].tap(LOOKAHEAD);
                ctx.set_output(c, i, delayed * gain);
            }
        }

        GAIN = g;
    }
}
