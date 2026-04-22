// Wavefolder — folds the waveform back when it exceeds +/-1.
//
// Applies gain (drive) to the input, then uses triangle-wave wrapping
// to fold the signal back into the +/-1 range. Each fold reflects the
// waveform, producing increasingly rich harmonic content as drive increases.
// Unlike clipping, wavefolding preserves energy and creates a distinctive
// metallic/buzzy timbre popular in modular synthesis.
//
// Params:
//   0 (Drive): Fold drive — 1.0 to 20.0

use conjuredsp::*;
setup!();

params! {
    DRIVE = param(1.0, 20.0).default(5.0),
}

#[no_mangle]
pub extern "C" fn process(
    input: *const f32,
    output: *mut f32,
    channels: i32,
    frame_count: i32,
    _sample_rate: f32,
) {
    let ctx = ctx(input, output, channels, frame_count, _sample_rate);

    unsafe {
        let drive = ctx.param(DRIVE);

        for c in 0..ctx.channels() {
            for i in 0..ctx.frames() {
                let x = ctx.input(c, i) * drive;
                // Triangle-wave fold: maps any value into [-1, 1]
                let t = (x + 1.0) * 0.25;
                let t = t - t.floor();
                ctx.set_output(c, i, 1.0 - (t * 4.0 - 2.0).abs());
            }
        }
    }
}
