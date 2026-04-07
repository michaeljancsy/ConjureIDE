// Auto-Pan — stereo auto-panner.
//
// Moves the signal between left and right channels using an LFO.
// Supports free-running or BPM-synced operation with multiple
// waveform shapes.

use conjuredsp::*;
setup!();

params! {
    SYNC = toggle(),
    RATE = param(0.1, 20.0).unit("Hz").default(2.0),
    DIVISION = choice(&["1/1", "1/2", "1/4", "1/8", "1/16"]).default(2.0),
    DEPTH = param(0.0, 1.0).default(0.8),
    SHAPE = choice(&["Sine", "Triangle", "Square"]).default(0.0),
}

static mut LFO_PHASE: f64 = 0.0;

fn triangle(phase: f64) -> f64 {
    let t = phase % 1.0;
    if t < 0.25 {
        t * 4.0
    } else if t < 0.75 {
        2.0 - t * 4.0
    } else {
        t * 4.0 - 4.0
    }
}

fn square(phase: f64) -> f64 {
    if (phase % 1.0) < 0.5 { 1.0 } else { -1.0 }
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
        let sync = ctx.param(SYNC) as f64;
        let free_rate = ctx.param(RATE) as f64;
        let div_idx = ctx.param(DIVISION) as usize;
        let depth = ctx.param(DEPTH) as f64;
        let shape_idx = ctx.param(SHAPE) as i32;

        let tempo = TRANSPORT_BUF[T_TEMPO] as f64;

        let divisions: [f64; 5] = [4.0, 2.0, 1.0, 0.5, 0.25];

        let rate_hz = if sync > 0.5 && tempo > 0.0 {
            let idx = if div_idx < 5 { div_idx } else { 4 };
            let beats = divisions[idx];
            tempo / 60.0 / beats
        } else {
            free_rate
        };

        if ctx.channels() < 2 {
            // Mono — just copy through
            for i in 0..ctx.frames() {
                ctx.set_output(0, i, ctx.input(0, i));
            }
            return;
        }

        let pi = core::f64::consts::PI;

        for i in 0..ctx.frames() {
            let two_pi = 2.0 * pi;
            let lfo_val = match shape_idx {
                1 => triangle(LFO_PHASE),
                2 => square(LFO_PHASE),
                _ => (two_pi * LFO_PHASE).sin(),
            };

            let pan = lfo_val * depth;
            let left_gain = ((pan + 1.0) * 0.25 * pi).cos();
            let right_gain = ((pan + 1.0) * 0.25 * pi).sin();

            // Sum to mono then pan
            let mono = (ctx.input(0, i) as f64 + ctx.input(1, i) as f64) * 0.5;
            ctx.set_output(0, i, (mono * left_gain) as f32);
            ctx.set_output(1, i, (mono * right_gain) as f32);

            LFO_PHASE = (LFO_PHASE + rate_hz / sr) % 1.0;
        }
    }
}
