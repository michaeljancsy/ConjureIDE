// Resonant State Variable Filter — multi-mode SVF (LP/HP/BP/Notch).
//
// Implements a digital state variable filter with low-pass output.
// The filter computes low-pass, high-pass, and band-pass simultaneously.
// Resonance controls the sharpness of the peak at the cutoff frequency.
// Change MODE constant to select output: 0=LP, 1=HP, 2=BP, 3=Notch.
//
// Params:
//   0 (Cutoff):    Filter cutoff — 20 to 20000 Hz (log)
//   1 (Resonance): Resonance Q — 0.5 to 10.0

use conjuredsp::*;
setup!();

params! {
    CUTOFF = freq(),
    RESONANCE = param(0.5, 10.0).default(1.0),
}

const MODE: usize = 0; // 0=LP, 1=HP, 2=BP, 3=Notch

// Persistent state per channel: [low, band]
// Use f64 to match Python's float64 precision in the coupled feedback loop.
static mut STATE_LOW: [f64; MAX_CH] = [0.0; MAX_CH];
static mut STATE_BAND: [f64; MAX_CH] = [0.0; MAX_CH];

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
        let cutoff_hz = ctx.param(CUTOFF) as f64;
        let resonance = ctx.param(RESONANCE) as f64;

        let f = 2.0 * (core::f64::consts::PI * cutoff_hz / sr).sin();
        let q = 1.0 / resonance;

        for c in 0..ctx.channels() {
            let mut low = STATE_LOW[c];
            let mut band = STATE_BAND[c];

            for i in 0..ctx.frames() {
                let x = ctx.input(c, i) as f64;
                low += f * band;
                let high = x - low - q * band;
                band += f * high;

                ctx.set_output(c, i, match MODE {
                    0 => low as f32,
                    1 => high as f32,
                    2 => band as f32,
                    _ => (low + high) as f32, // notch
                });
            }

            if !low.is_finite() || !band.is_finite() {
                low = 0.0;
                band = 0.0;
            }
            STATE_LOW[c] = low;
            STATE_BAND[c] = band;
        }
    }
}
