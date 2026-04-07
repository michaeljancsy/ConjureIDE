// Stutter — rhythmic glitch stutter effect.
//
// Captures a short chunk of audio and repeats it rapidly, creating
// a machine-gun stutter effect. BPM sync locks the stutter to the
// beat grid.

use conjuredsp::*;
setup!();

params! {
    SYNC = toggle().default(1.0),
    RATE = param(2.0, 32.0).unit("Hz").default(8.0),
    DIVISION = choice(&["1/4", "1/8", "1/16", "1/32"]).default(2.0),
    LENGTH = param(0.1, 1.0).default(0.5),
}

const DIVISIONS: [f64; 4] = [1.0, 0.5, 0.25, 0.125];
const MAX_SAMPLES: usize = 48000;

static mut BUFFER: [[f32; MAX_SAMPLES]; MAX_CH] = [[0.0; MAX_SAMPLES]; MAX_CH];
static mut WRITE_POS: usize = 0;
static mut READ_POS: usize = 0;
static mut PHASE: f64 = 0.0;
static mut CAPTURING: bool = true;
static mut CHUNK_LEN: usize = 0;

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
        let sync = ctx.param(SYNC) as f64;
        let rate_param = ctx.param(RATE) as f64;
        let div_idx_raw = ctx.param(DIVISION) as f64;
        let length_frac = ctx.param(LENGTH) as f64;
        let tempo = TRANSPORT_BUF[T_TEMPO] as f64;

        let rate_hz = if sync > 0.5 && tempo > 0.0 {
            let mut idx = div_idx_raw.round() as usize;
            if idx >= DIVISIONS.len() { idx = DIVISIONS.len() - 1; }
            let beats = DIVISIONS[idx];
            tempo / 60.0 / beats
        } else {
            rate_param
        };

        let period_samples = (sr / rate_hz) as usize;
        CHUNK_LEN = ((period_samples as f64 * length_frac) as usize).max(1);
        if CHUNK_LEN > MAX_SAMPLES { CHUNK_LEN = MAX_SAMPLES; }

        for i in 0..ctx.frames() {
            let old_phase = PHASE;
            PHASE = (PHASE + rate_hz / sr) % 1.0;

            // On phase reset, start capturing
            if PHASE < old_phase {
                CAPTURING = true;
                WRITE_POS = 0;
                READ_POS = 0;
            }

            if CAPTURING && WRITE_POS < CHUNK_LEN {
                for ch in 0..ctx.channels() {
                    BUFFER[ch][WRITE_POS] = ctx.input(ch, i);
                }
                WRITE_POS += 1;
                if WRITE_POS >= CHUNK_LEN {
                    CAPTURING = false;
                    READ_POS = 0;
                }
            }

            // Play back the captured chunk on repeat
            if CHUNK_LEN > 0 {
                for ch in 0..ctx.channels() {
                    ctx.set_output(ch, i, BUFFER[ch][READ_POS % CHUNK_LEN]);
                }
                READ_POS = (READ_POS + 1) % CHUNK_LEN;
            } else {
                for ch in 0..ctx.channels() {
                    ctx.set_output(ch, i, ctx.input(ch, i));
                }
            }
        }
    }
}
