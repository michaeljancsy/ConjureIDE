// Passthrough — copies input audio to output unchanged.
//
// The simplest possible Rust DSP script. Each sample is copied from the input
// buffer to the output buffer with no modification.

use conjuredsp::*;
setup!();

/// Passthrough — copies input to output unchanged.
///
/// Iterates over all channel-sequential samples (channels x frames) and copies each
/// input sample directly to the output buffer. No parameters are declared.
#[no_mangle]
pub extern "C" fn process(
    input: *const f32,
    output: *mut f32,
    channels: i32,
    frame_count: i32,
    _sample_rate: f32,
) {
    let ctx = ctx(input, output, channels, frame_count, _sample_rate);
    for c in 0..ctx.channels() {
        for i in 0..ctx.frames() {
            ctx.set_output(c, i, ctx.input(c, i));
        }
    }
}
