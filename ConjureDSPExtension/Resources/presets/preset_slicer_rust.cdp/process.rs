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
const MAX_CHUNK: usize = 19200;

params! {
    RATE = time_ms().min(10.0).max(500.0).default(100.0),
}

// Double buffers for record and playback.
persist_buf!(BUF_A: [[f32; MAX_CHUNK]; MAX_CH] = [[0.0; MAX_CHUNK]; MAX_CH]);
persist_buf!(BUF_B: [[f32; MAX_CHUNK]; MAX_CH] = [[0.0; MAX_CHUNK]; MAX_CH]);
persist!(RECORDING_A: bool = true); // true = recording to A, playing from B
persist!(WRITE_POS: usize = 0);

process! { ctx =>
    let chunk_ms = ctx.param(RATE);
    let mut chunk_size = (chunk_ms * 0.001 * ctx.sample_rate()) as usize;
    if chunk_size > MAX_CHUNK {
        chunk_size = MAX_CHUNK;
    }

    let mut wp = WRITE_POS.get();
    let mut recording_a = RECORDING_A.get();

    BUF_A.with_mut(|buf_a| {
        BUF_B.with_mut(|buf_b| {
            for i in 0..ctx.frames() {
                let read_pos = chunk_size - 1 - wp;

                for c in 0..ctx.channels() {
                    if recording_a {
                        // Record to A, play from B
                        buf_a[c][wp] = ctx.input(c, i);
                        ctx.set_output(c, i, buf_b[c][read_pos]);
                    } else {
                        // Record to B, play from A
                        buf_b[c][wp] = ctx.input(c, i);
                        ctx.set_output(c, i, buf_a[c][read_pos]);
                    }
                }

                wp += 1;
                if wp >= chunk_size {
                    // Swap buffers
                    recording_a = !recording_a;
                    wp = 0;
                }
            }
        });
    });

    WRITE_POS.set(wp);
    RECORDING_A.set(recording_a);
}
