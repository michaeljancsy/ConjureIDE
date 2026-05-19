// Glitch Repeater — triggered loop capture and repeat.
//
// When the hold toggle is engaged, captures a short segment and
// repeats it indefinitely with optional decay.

use conjuredsp::*;
setup!();

params! {
    HOLD = toggle().default(0.0),
    LENGTH = time_ms().min(10.0).max(200.0).default(50.0),
    DECAY = param(0.8, 1.0).default(0.95),
}

const MAX_SAMPLES: usize = 9700; // ~200ms at 48kHz + 100

static mut BUFFER: [[f32; MAX_SAMPLES]; MAX_CH] = [[0.0; MAX_SAMPLES]; MAX_CH];
static mut WRITE_POS: usize = 0;
static mut HELD: bool = false;
static mut HOLD_LEN: usize = 0;
static mut READ_POS: usize = 0;
static mut GAIN: f64 = 1.0;

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
        let hold = ctx.param(HOLD) as f64 > 0.5;
        let length_ms = ctx.param(LENGTH) as f64;
        let decay = ctx.param(DECAY) as f64;

        let loop_len = ((length_ms * 0.001 * sr) as usize).max(1).min(MAX_SAMPLES);

        if hold && !HELD {
            // Just engaged - capture buffer
            HELD = true;
            HOLD_LEN = loop_len;
            READ_POS = 0;
            GAIN = 1.0;
        } else if !hold {
            HELD = false;
        }

        for i in 0..ctx.frames() {
            if HELD {
                // Play from captured loop
                for ch in 0..ctx.channels() {
                    ctx.set_output(ch, i, (BUFFER[ch][READ_POS % HOLD_LEN] as f64 * GAIN) as f32);
                }

                READ_POS += 1;
                if READ_POS >= HOLD_LEN {
                    READ_POS = 0;
                    GAIN *= decay;
                }
            } else {
                // Normal pass-through, keep writing to buffer
                for ch in 0..ctx.channels() {
                    BUFFER[ch][WRITE_POS % MAX_SAMPLES] = ctx.input(ch, i);
                    ctx.set_output(ch, i, ctx.input(ch, i));
                }
                WRITE_POS = (WRITE_POS + 1) % MAX_SAMPLES;
            }
        }
    }
}
