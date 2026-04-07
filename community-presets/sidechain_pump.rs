// Sidechain Pump — EDM ducking/pumping effect.

use conjuredsp::*;
setup!();

params! {
    SYNC = toggle().default(1.0),
    RATE = param(1.0, 20.0).unit("Hz").default(4.0),
    DIVISION = choice(&["1/4", "1/8", "1/16", "1/2"]),
    DEPTH = param(0.0, 1.0).default(0.8),
    CURVE = param(0.1, 3.0).default(1.0),
}

const DIVISIONS: [f64; 4] = [1.0, 0.5, 0.25, 2.0];

static mut PHASE: f64 = 0.0;

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
        let depth = ctx.param(DEPTH) as f64;
        let curve = ctx.param(CURVE) as f64;
        let tempo = TRANSPORT_BUF[T_TEMPO] as f64;

        let rate_hz = if ctx.param(SYNC) > 0.5 && tempo > 0.0 {
            let div_idx = (ctx.param(DIVISION) as usize).min(DIVISIONS.len() - 1);
            let beats = DIVISIONS[div_idx];
            tempo / 60.0 / beats
        } else {
            ctx.param(RATE) as f64
        };

        for i in 0..ctx.frames() {
            let pump = PHASE.powf(curve);
            let vol = 1.0 - depth * (1.0 - pump);

            for c in 0..ctx.channels() {
                ctx.set_output(c, i, (ctx.input(c, i) as f64 * vol) as f32);
            }

            PHASE = (PHASE + rate_hz / sr) % 1.0;
        }
    }
}
