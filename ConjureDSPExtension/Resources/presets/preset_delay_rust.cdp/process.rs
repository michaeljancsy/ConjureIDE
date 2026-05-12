// Simple Delay — echo effect with feedback.
//
// Delays the signal by a fixed time and feeds the delayed output back
// into the delay line. Each repeat is attenuated by the feedback amount,
// creating a decaying echo. The dry/wet mix controls the balance between
// the original signal and the delayed signal.
//
// Params:
//   0 (Time):     Delay time — 10 to 500 ms
//   1 (Feedback): Feedback amount — 0.0 to 0.95
//   2 (Mix):      Dry/wet mix — 0.0 to 1.0

use conjuredsp::*;
const MAX_DELAY: usize = 48000;

params! {
    TIME = time_ms().min(10.0).max(500.0).default(250.0),
    FEEDBACK = param(0.0, 0.95).default(0.5),
    MIX = mix(),
}

// Persistent state — 384 KB delay buffer (the canonical persist_buf!
// motivating case) plus a scalar write index.
persist_buf!(DELAY_BUF: [[f32; MAX_DELAY]; MAX_CH] = [[0.0; MAX_DELAY]; MAX_CH]);
persist!(WRITE_POS: usize = 0);

process! { ctx =>
    let delay_ms = ctx.param(TIME);
    let feedback = ctx.param(FEEDBACK);
    let mix = ctx.param(MIX);

    let mut delay_samples = (delay_ms * 0.001 * ctx.sample_rate()) as usize;
    if delay_samples >= MAX_DELAY {
        delay_samples = MAX_DELAY - 1;
    }

    let mut wp = WRITE_POS.get();

    DELAY_BUF.with_mut(|delay_buf| {
        for i in 0..ctx.frames() {
            let rp = (wp + MAX_DELAY - delay_samples) % MAX_DELAY;

            for c in 0..ctx.channels() {
                let delayed = delay_buf[c][rp];

                // Write input + feedback to delay line
                delay_buf[c][wp] = ctx.input(c, i) + delayed * feedback;

                // Mix dry + wet
                ctx.set_output(c, i, ctx.input(c, i) * (1.0 - mix) + delayed * mix);
            }

            wp = (wp + 1) % MAX_DELAY;
        }
    });

    WRITE_POS.set(wp);
}
