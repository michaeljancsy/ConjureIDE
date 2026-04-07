// Transient Shaper — attack and sustain design.

use conjuredsp::*;
setup!();

params! {
    ATTACK = db().min(-12.0).max(12.0).default(0.0),
    SUSTAIN = db().min(-12.0).max(12.0).default(0.0),
    SPEED = param(5.0, 50.0).unit("ms").default(15.0),
}

static mut FAST_ENV: f64 = 0.0;
static mut SLOW_ENV: f64 = 0.0;

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
        let attack_gain = db_to_gain(ctx.param(ATTACK) as f64);
        let sustain_gain = db_to_gain(ctx.param(SUSTAIN) as f64);
        let speed_ms = ctx.param(SPEED) as f64;

        let fast_coeff = smooth_coeff(speed_ms * 0.2, sr);
        let slow_coeff = smooth_coeff(speed_ms * 3.0, sr);

        for i in 0..ctx.frames() {
            let mut peak: f64 = 0.0;
            for c in 0..ctx.channels() {
                let v = (ctx.input(c, i) as f64).abs();
                if v > peak { peak = v; }
            }

            if peak > FAST_ENV {
                FAST_ENV = fast_coeff * FAST_ENV + (1.0 - fast_coeff) * peak;
            } else {
                FAST_ENV = fast_coeff * FAST_ENV + (1.0 - fast_coeff) * peak;
            }

            if peak > SLOW_ENV {
                SLOW_ENV = slow_coeff * SLOW_ENV + (1.0 - slow_coeff) * peak;
            } else {
                SLOW_ENV = slow_coeff * SLOW_ENV + (1.0 - slow_coeff) * peak;
            }

            let diff = FAST_ENV - SLOW_ENV;

            let gain = if diff > 0.0 {
                1.0 + diff * (attack_gain - 1.0) * 5.0
            } else {
                sustain_gain
            };

            let gain = gain.max(0.01).min(10.0);

            for c in 0..ctx.channels() {
                ctx.set_output(c, i, (ctx.input(c, i) as f64 * gain) as f32);
            }
        }
    }
}
