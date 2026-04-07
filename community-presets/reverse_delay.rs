// Reverse Delay — backwards echoes.
//
// Captures chunks of audio, reverses them, and plays them back
// after a delay. Creates an eerie, otherworldly effect as if the
// audio is being played in reverse.

use conjuredsp::*;
setup!();

params! {
    TIME = time_ms().min(100.0).max(1000.0).default(300.0),
    FEEDBACK = param(0.0, 0.9).default(0.3),
    MIX = mix().default(0.5),
}

const MAX_SAMPLES: usize = 49152; // ~1.0s at 48kHz + 1024

static mut BUFFER: [[f32; MAX_SAMPLES]; MAX_CH] = [[0.0; MAX_SAMPLES]; MAX_CH];
static mut OUTPUT_BUF_REV: [[f32; MAX_SAMPLES]; MAX_CH] = [[0.0; MAX_SAMPLES]; MAX_CH];
static mut WRITE_POS: usize = 0;
static mut READ_COUNTER: usize = 0;

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
        let delay_ms = ctx.param(TIME) as f64;
        let feedback = ctx.param(FEEDBACK) as f64;
        let wet_mix = ctx.param(MIX) as f64;

        let chunk = (delay_ms * 0.001 * sr) as usize;
        let buf_len = MAX_SAMPLES;

        for i in 0..ctx.frames() {
            for ch in 0..ctx.channels() {
                BUFFER[ch][WRITE_POS] = ctx.input(ch, i);
            }

            READ_COUNTER += 1;

            if READ_COUNTER >= chunk {
                // Reverse the chunk we just recorded into output buffer
                for ch in 0..ctx.channels() {
                    let start = (WRITE_POS + buf_len - chunk + 1) % buf_len;
                    for j in 0..chunk {
                        let src = (start + j) % buf_len;
                        let dst = (start + chunk - 1 - j) % buf_len;
                        OUTPUT_BUF_REV[ch][dst] = BUFFER[ch][src];
                    }
                }

                READ_COUNTER = 0;
            }

            // Read from output buffer (one chunk behind)
            let read_pos = (WRITE_POS + buf_len - chunk) % buf_len;

            for ch in 0..ctx.channels() {
                let wet = OUTPUT_BUF_REV[ch][read_pos] as f64;

                // Feedback: feed reversed audio back into input buffer
                BUFFER[ch][WRITE_POS] += (wet * feedback) as f32;

                ctx.set_output(
                    ch,
                    i,
                    (ctx.input(ch, i) as f64 * (1.0 - wet_mix) + wet * wet_mix) as f32,
                );
            }

            WRITE_POS = (WRITE_POS + 1) % buf_len;
        }
    }
}
