// Bitcrush — bit depth reduction and sample rate reduction.
//
// Applies two lo-fi effects in series:
// 1. Bit depth reduction: quantizes the signal to fewer amplitude levels,
//    producing a gritty, digital distortion.
// 2. Sample rate reduction: holds every Nth sample, discarding the rest,
//    which introduces aliasing artifacts and a characteristic stepped sound.
//
// Params:
//   0 (Bit Depth):  Quantization depth — 1 to 16 bits
//   1 (Downsample): Sample rate reduction factor — 1x to 16x

use conjuredsp::*;
setup!();

params! {
    BIT_DEPTH = param(1.0, 16.0).unit("bits").default(16.0),
    DOWNSAMPLE = param(1.0, 16.0).unit("x").default(1.0),
}

// Persistent held sample per channel for sample-rate reduction
static mut HELD: [f32; MAX_CH] = [0.0; MAX_CH];

/// Bitcrush — bit depth reduction and sample rate reduction.
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
        let bit_depth = ctx.param(BIT_DEPTH) as i32;       // truncate to match Python's int()
        let downsample = ctx.param(DOWNSAMPLE) as usize;  // truncate to match Python's int()
        let levels = (1 << bit_depth) as f32;

        for i in 0..ctx.frames() {
            for c in 0..ctx.channels() {
                // Bit depth reduction: quantize to fewer levels
                let crushed = (ctx.input(c, i) * levels).round() / levels;
                // Sample rate reduction: hold every Nth sample
                if i % downsample == 0 {
                    HELD[c] = crushed;
                }
                ctx.set_output(c, i, HELD[c]);
            }
        }
    }
}
