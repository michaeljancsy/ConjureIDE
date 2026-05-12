// Passthrough — copies input audio to output unchanged.
//
// The simplest possible Rust DSP script. Each sample is copied from the input
// buffer to the output buffer with no modification.

use conjuredsp::*;
/// Passthrough — copies input to output unchanged.
///
/// Iterates over all channel-sequential samples (channel_count x frames) and copies each
/// input sample directly to the output buffer. No parameters are declared.
process! { ctx =>
    for c in 0..ctx.channels() {
        for i in 0..ctx.frames() {
            ctx.set_output(c, i, ctx.input(c, i));
        }
    }
}
