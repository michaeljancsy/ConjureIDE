// Chorus — modulated delay for thickening.
//
// Uses a short delay line with an LFO-modulated read position to create
// a detuned copy of the signal. The modulated copy is mixed with the dry
// signal, producing a rich, thickened sound. Linear interpolation is used
// for sub-sample delay accuracy.
//
// Params:
//   0 (Rate):  LFO rate — 0.1 to 2.0 Hz
//   1 (Depth): Modulation depth — 0.5 to 15.0 ms
//   2 (Delay): Base delay — 2.0 to 30.0 ms
//   3 (Mix):   Dry/wet mix — 0.0 to 1.0

use conjuredsp::*;
setup!();

const MAX_DELAY: usize = 2048;

params! {
    RATE = param(0.1, 2.0).unit("Hz").default(0.5),
    DEPTH = param(0.5, 15.0).unit("ms").default(5.0),
    DELAY = param(2.0, 30.0).unit("ms").default(10.0),
    MIX = mix(),
}

// Persistent state
static mut DELAY_BUF: [[f32; MAX_DELAY]; MAX_CH] = [[0.0; MAX_DELAY]; MAX_CH];
static mut WRITE_POS: usize = 0;
// Use f64 to match Python's float64 precision in the phase accumulator.
static mut LFO_PHASE: f64 = 0.0;

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
    let two_pi = 2.0 * core::f64::consts::PI;

    unsafe {
        let rate_hz = ctx.param(RATE) as f64;
        let depth_ms = ctx.param(DEPTH) as f64;
        let base_delay_ms = ctx.param(DELAY) as f64;
        let mix = ctx.param(MIX) as f64;

        let lfo_inc = two_pi * rate_hz / sr;
        let mut phase = LFO_PHASE;
        let mut wp = WRITE_POS;

        for i in 0..ctx.frames() {
            // LFO modulates delay time
            let delay_samples = (base_delay_ms + depth_ms * phase.sin()) * sr / 1000.0;

            for c in 0..ctx.channels() {
                // Write input to delay line
                DELAY_BUF[c][wp] = ctx.input(c, i);

                // Read with linear interpolation (f64 to match Python)
                let mut read_pos = wp as f64 - delay_samples;
                if read_pos < 0.0 {
                    read_pos += MAX_DELAY as f64;
                }
                let idx0 = (read_pos as usize) % MAX_DELAY;
                let idx1 = (idx0 + 1) % MAX_DELAY;
                let frac = read_pos - read_pos.floor();
                let delayed = DELAY_BUF[c][idx0] as f64 * (1.0 - frac)
                    + DELAY_BUF[c][idx1] as f64 * frac;

                // Mix dry + wet
                ctx.set_output(c, i, (ctx.input(c, i) as f64 * (1.0 - mix) + delayed * mix) as f32);
            }

            phase += lfo_inc;
            wp = (wp + 1) % MAX_DELAY;
        }

        LFO_PHASE = phase % two_pi;
        WRITE_POS = wp;
    }
}
