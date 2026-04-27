// Reverse Slicer — records chunks and plays them backwards.
//
// Divides the audio into fixed-length chunks. While recording each new
// chunk, the previous chunk is played back in reverse. This creates a
// glitchy, backwards effect where every CHUNK_MS milliseconds the audio
// reverses direction. Uses double-buffering: one buffer records while
// the other plays back reversed.
//
// Params:
//   0 (Rate): Chunk length — 10 to 500 ms

use conjuredsp::*;
setup!();

const MAX_CHUNK: usize = 19200;

params! {
    RATE = time_ms().min(10.0).max(500.0).default(100.0),
}

// Double buffers for record and playback
static mut BUF_A: [[f32; MAX_CHUNK]; MAX_CH] = [[0.0; MAX_CHUNK]; MAX_CH];
static mut BUF_B: [[f32; MAX_CHUNK]; MAX_CH] = [[0.0; MAX_CHUNK]; MAX_CH];
static mut RECORDING_A: bool = true; // true = recording to A, playing from B
static mut WRITE_POS: usize = 0;

#[no_mangle]
pub extern "C" fn process(
    input: *const f32,
    output: *mut f32,
    channel_count: i32,
    frame_count: i32,
    sample_rate: f32,
) {
    let ctx = ctx(input, output, channel_count, frame_count, sample_rate);

    unsafe {
        let chunk_ms = ctx.param(RATE);
        let mut chunk_size = (chunk_ms * 0.001 * sample_rate) as usize;
        if chunk_size > MAX_CHUNK {
            chunk_size = MAX_CHUNK;
        }

        let mut wp = WRITE_POS;

        for i in 0..ctx.frames() {
            let read_pos = chunk_size - 1 - wp;

            for c in 0..ctx.channels() {
                if RECORDING_A {
                    // Record to A, play from B
                    BUF_A[c][wp] = ctx.input(c, i);
                    ctx.set_output(c, i, BUF_B[c][read_pos]);
                } else {
                    // Record to B, play from A
                    BUF_B[c][wp] = ctx.input(c, i);
                    ctx.set_output(c, i, BUF_A[c][read_pos]);
                }
            }

            wp += 1;
            if wp >= chunk_size {
                // Swap buffers
                RECORDING_A = !RECORDING_A;
                wp = 0;
            }
        }

        WRITE_POS = wp;
    }
}
