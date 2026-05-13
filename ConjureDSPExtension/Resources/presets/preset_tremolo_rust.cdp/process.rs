// Tremolo — sine-based amplitude modulation.
//
// Modulates the audio amplitude with a low-frequency sine oscillator (LFO).
// Supports free-running Hz rate or BPM-synced note divisions.
//
// Params:
//   0 (Sync):     0 = free Hz, 1 = BPM sync
//   1 (Rate):     LFO rate in free mode — 0.5 to 20 Hz
//   2 (Division): Note division in BPM mode — 0=1/1, 1=1/2, 2=1/4, 3=1/8, 4=1/16, 5=1/4T, 6=1/8T
//   3 (Depth):    Tremolo depth — 0.0 to 1.0

use conjuredsp::*;
params! {
    SYNC = toggle(),
    RATE = param(0.5, 20.0).unit("Hz").default(5.0),
    DIVISION = choice(&["1/1", "1/2", "1/4", "1/8", "1/16", "1/4T", "1/8T"]).default(2.0),
    DEPTH = param(0.0, 1.0).default(0.5),
}

// Division mapping: 0=1/1, 1=1/2, 2=1/4, 3=1/8, 4=1/16, 5=1/4T, 6=1/8T
// Values are in beats (quarter notes)
const DIVISIONS: [f64; 7] = [4.0, 2.0, 1.0, 0.5, 0.25, 2.0 / 3.0, 1.0 / 3.0];

// Persistent phase across callbacks. f64 to match Python's float64
// precision in the phase accumulator.
persist!(PHASE: f64 = 0.0);

/// Tremolo — sine-based amplitude modulation.
///
/// Computes a per-sample LFO gain using a sine wave, then multiplies
/// each input sample by that gain. The phase accumulates across callbacks so the
/// modulation is seamless between audio buffers. All channels share the same LFO.
process! { ctx =>
    let sr = ctx.sample_rate() as f64;
    let two_pi = 2.0 * core::f64::consts::PI;

    let sync = ctx.param(SYNC) as f64;
    let depth = ctx.param(DEPTH) as f64;
    let tempo = unsafe { TRANSPORT_BUF[T_TEMPO] } as f64;

    // Determine LFO rate
    let rate_hz = if sync > 0.5 && tempo > 0.0 {
        let div_idx_raw = ctx.param(DIVISION) as f64;
        let div_idx = div_idx_raw.round() as usize;
        let div_idx = if div_idx >= DIVISIONS.len() { DIVISIONS.len() - 1 } else { div_idx };
        let beats = DIVISIONS[div_idx];
        tempo / 60.0 / beats
    } else {
        ctx.param(RATE) as f64
    };

    let phase_inc = two_pi * rate_hz / sr;
    let mut phase = PHASE.get();

    for i in 0..ctx.frames() {
        let lfo = 1.0 - depth * 0.5 * (1.0 + phase.sin());
        for c in 0..ctx.channels() {
            ctx.set_output(c, i, (ctx.input(c, i) as f64 * lfo) as f32);
        }
        phase += phase_inc;
    }

    PHASE.set(phase % two_pi);
}
