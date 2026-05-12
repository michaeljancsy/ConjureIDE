// Ping-Pong Delay — stereo bouncing echo.
//
// Creates echoes that alternate between left and right channel_count. The
// input feeds into the left delay, the left delay's output feeds into
// the right delay, and the right delay feeds back into the left. This
// creates a bouncing stereo effect. For mono input, falls back to a
// simple delay with feedback.
//
// Params:
//   0 (Time):     Delay time — 50 to 500 ms
//   1 (Feedback): Feedback amount — 0.0 to 0.95
//   2 (Mix):      Dry/wet mix — 0.0 to 1.0

use conjuredsp::*;
const MAX_DELAY: usize = 48000;

params! {
    TIME = time_ms().min(50.0).max(500.0).default(250.0),
    FEEDBACK = param(0.0, 0.95).default(0.5),
    MIX = mix(),
}

// Persistent state: separate left and right delay lines
static mut LEFT_BUF: [f32; MAX_DELAY] = [0.0; MAX_DELAY];
static mut RIGHT_BUF: [f32; MAX_DELAY] = [0.0; MAX_DELAY];
static mut WRITE_POS: usize = 0;

process! { ctx =>
    unsafe {
        let delay_ms = ctx.param(TIME);
        let feedback = ctx.param(FEEDBACK);
        let mix = ctx.param(MIX);

        let mut delay_samples = (delay_ms * 0.001 * ctx.sample_rate()) as usize;
        if delay_samples >= MAX_DELAY {
            delay_samples = MAX_DELAY - 1;
        }

        let mut wp = WRITE_POS;

        if ctx.channels() < 2 {
            // Mono: simple delay with feedback
            for i in 0..ctx.frames() {
                let rp = (wp + MAX_DELAY - delay_samples) % MAX_DELAY;
                let delayed = LEFT_BUF[rp];
                LEFT_BUF[wp] = ctx.input(0, i) + delayed * feedback;
                ctx.set_output(0, i, ctx.input(0, i) * (1.0 - mix) + delayed * mix);
                wp = (wp + 1) % MAX_DELAY;
            }
        } else {
            // Stereo: ping-pong
            for i in 0..ctx.frames() {
                let rp = (wp + MAX_DELAY - delay_samples) % MAX_DELAY;

                let left_delayed = LEFT_BUF[rp];
                let right_delayed = RIGHT_BUF[rp];

                // Input goes to left, left feeds right, right feeds back to left
                let mono_in = (ctx.input(0, i) + ctx.input(1, i)) * 0.5;
                LEFT_BUF[wp] = mono_in + right_delayed * feedback;
                RIGHT_BUF[wp] = left_delayed * feedback;

                // Mix dry + wet
                ctx.set_output(0, i, ctx.input(0, i) * (1.0 - mix) + left_delayed * mix);
                ctx.set_output(1, i, ctx.input(1, i) * (1.0 - mix) + right_delayed * mix);

                wp = (wp + 1) % MAX_DELAY;
            }
        }

        WRITE_POS = wp;
    }
}
