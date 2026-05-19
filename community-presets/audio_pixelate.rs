// Audio Pixelate — block-based audio reduction.
//
// Divides audio into blocks and replaces each block with its
// average value, like pixelating an image.

use conjuredsp::*;
setup!();

params! {
    BLOCK_SIZE = param(2.0, 512.0).default(64.0),
    MIX = mix().default(0.7),
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

    unsafe {
        let block = (ctx.param(BLOCK_SIZE) as usize).max(2);
        let wet_mix = ctx.param(MIX) as f64;

        for ch in 0..ctx.channels() {
            let mut start = 0;
            while start < ctx.frames() {
                let end = (start + block).min(ctx.frames());

                // Average the block
                let mut avg = 0.0f64;
                let count = end - start;
                for i in start..end {
                    avg += ctx.input(ch, i) as f64;
                }
                avg /= count as f64;

                // Fill block with average
                for i in start..end {
                    let x = ctx.input(ch, i) as f64;
                    ctx.set_output(ch, i, (x * (1.0 - wet_mix) + avg * wet_mix) as f32);
                }

                start = end;
            }
        }
    }
}
