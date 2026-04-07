// Buffer Shuffle — randomized audio chunk rearrangement.
//
// Captures audio in beat-synced chunks and rearranges them randomly.
// Creates beat-mangling, cut-up effects.

use conjuredsp::*;
setup!();

params! {
    SIZE = choice(&["1/16", "1/8", "1/4"]).default(1.0),
    SHUFFLE = param(0.0, 1.0).default(0.5),
    REVERSE = param(0.0, 1.0).default(0.3),
    MIX = mix().default(0.7),
}

const DIVISIONS: [f64; 3] = [0.25, 0.5, 1.0];
const MAX_BUF: usize = 192000; // enough for 8 chunks at slow tempos

static mut BUFFER: [[f32; MAX_BUF]; MAX_CH] = [[0.0; MAX_BUF]; MAX_CH];
static mut SHUFFLED: [[f32; MAX_BUF]; MAX_CH] = [[0.0; MAX_BUF]; MAX_CH];
static mut WRITE_POS: usize = 0;
static mut CHUNK_SIZE: usize = 0;
static mut RNG_STATE: u32 = 12345;

fn rng() -> f64 {
    unsafe {
        RNG_STATE = RNG_STATE.wrapping_mul(1664525).wrapping_add(1013904223);
        RNG_STATE as f64 / 4294967296.0
    }
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
    let sr = sample_rate as f64;

    unsafe {
        let div_idx_raw = ctx.param(SIZE) as f64;
        let mut div_idx = div_idx_raw.round() as usize;
        if div_idx >= DIVISIONS.len() { div_idx = DIVISIONS.len() - 1; }
        let beats = DIVISIONS[div_idx];
        let shuffle_prob = ctx.param(SHUFFLE) as f64;
        let reverse_prob = ctx.param(REVERSE) as f64;
        let wet_mix = ctx.param(MIX) as f64;

        let tempo = TRANSPORT_BUF[T_TEMPO] as f64;

        // Calculate chunk size
        let chunk = if tempo > 0.0 {
            let chunk_seconds = beats * 60.0 / tempo;
            (chunk_seconds * sr) as usize
        } else {
            (0.125 * sr) as usize
        };
        let chunk = chunk.max(64).min(sr as usize * 2);
        let max_buf = chunk * 8;
        let max_buf = max_buf.min(MAX_BUF);

        CHUNK_SIZE = chunk;

        for i in 0..ctx.frames() {
            // Write to buffer
            let wp = WRITE_POS % max_buf;
            for ch in 0..ctx.channels() {
                BUFFER[ch][wp] = ctx.input(ch, i);
            }
            WRITE_POS += 1;

            // At chunk boundary, maybe shuffle
            if WRITE_POS % chunk == 0 && WRITE_POS > 0 {
                let chunk_start = (WRITE_POS - chunk) % max_buf;

                if rng() < shuffle_prob {
                    // Pick a random previous chunk to play instead
                    let num_chunks = (WRITE_POS / chunk).min(8);
                    let src_chunk = (rng() * num_chunks.max(1) as f64) as usize;
                    let src_start = (chunk_start + max_buf - src_chunk * chunk) % max_buf;

                    for ch in 0..ctx.channels() {
                        for j in 0..chunk {
                            SHUFFLED[ch][(chunk_start + j) % max_buf] =
                                BUFFER[ch][(src_start + j) % max_buf];
                        }
                    }

                    // Maybe reverse
                    if rng() < reverse_prob {
                        for ch in 0..ctx.channels() {
                            // Reverse in place
                            let mut left = 0;
                            let mut right = chunk - 1;
                            while left < right {
                                let li = (chunk_start + left) % max_buf;
                                let ri = (chunk_start + right) % max_buf;
                                let tmp = SHUFFLED[ch][li];
                                SHUFFLED[ch][li] = SHUFFLED[ch][ri];
                                SHUFFLED[ch][ri] = tmp;
                                left += 1;
                                right -= 1;
                            }
                        }
                    }
                } else {
                    for ch in 0..ctx.channels() {
                        for j in 0..chunk {
                            SHUFFLED[ch][(chunk_start + j) % max_buf] =
                                BUFFER[ch][(chunk_start + j) % max_buf];
                        }
                    }
                }
            }

            // Read from shuffled buffer (one chunk behind)
            let rp = (WRITE_POS + max_buf - chunk) % max_buf;

            for ch in 0..ctx.channels() {
                let wet = if WRITE_POS > chunk {
                    SHUFFLED[ch][rp] as f64
                } else {
                    ctx.input(ch, i) as f64
                };
                let dry = ctx.input(ch, i) as f64;
                ctx.set_output(ch, i, (dry * (1.0 - wet_mix) + wet * wet_mix) as f32);
            }
        }
    }
}
