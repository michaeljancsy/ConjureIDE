// Tape Stop — turntable/tape brake effect.
//
// When engaged, simulates a record player or tape machine being
// stopped. When released, the audio speeds back up.

use conjuredsp::*;
setup!();

params! {
    ENGAGE = toggle().default(0.0),
    SPEED = param(0.1, 3.0).unit("s").default(1.0),
    RESTART = param(0.05, 1.0).unit("s").default(0.3),
}

const MAX_DELAY: usize = 192000;

static mut DELAYS: [DelayLine<MAX_DELAY>; MAX_CH] = [DelayLine::new(); MAX_CH];
static mut RATE: f64 = 1.0;
static mut RAMP_POS: f64 = 0.0;
static mut WAS_ENGAGED: bool = false;
static mut RESTARTING: bool = false;

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
        let engaged = ctx.param(ENGAGE) as f64 > 0.5;
        let stop_time = ctx.param(SPEED) as f64;
        let restart_time = ctx.param(RESTART) as f64;
        let fc = frame_count as f64;

        // Detect state changes
        if engaged && !WAS_ENGAGED {
            RESTARTING = false;
        } else if !engaged && WAS_ENGAGED {
            RESTARTING = true;
        }
        WAS_ENGAGED = engaged;

        for i in 0..ctx.frames() {
            if engaged && !RESTARTING {
                // Slowing down
                let decel = 1.0 / (stop_time * sr);
                RATE = (RATE - decel).max(0.0);
            } else if RESTARTING {
                // Speeding back up
                let accel = 1.0 / (restart_time * sr);
                RATE = (RATE + accel).min(1.0);
                if RATE >= 1.0 {
                    RESTARTING = false;
                }
            } else {
                RATE = 1.0;
            }

            for ch in 0..ctx.channels() {
                DELAYS[ch].write(ctx.input(ch, i));
            }

            // Read at variable rate (pitch drops as rate decreases)
            RAMP_POS += RATE;
            if RAMP_POS >= MAX_DELAY as f64 {
                RAMP_POS = RAMP_POS % MAX_DELAY as f64;
            }

            let read_delay = (fc - RAMP_POS % fc).max(1.0);
            let rd = if read_delay > (MAX_DELAY - 1) as f64 {
                (MAX_DELAY - 1) as f64
            } else {
                read_delay
            };

            for ch in 0..ctx.channels() {
                if RATE < 0.01 {
                    ctx.set_output(ch, i, 0.0);
                } else {
                    let out = DELAYS[ch].read(rd) as f64 * (RATE * 2.0).min(1.0);
                    ctx.set_output(ch, i, out as f32);
                }
            }
        }
    }
}
