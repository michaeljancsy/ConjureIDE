// DJ Kill EQ — 3-band isolator with kill switches.

use conjuredsp::*;
setup!();

params! {
    LOW = db().min(-60.0).max(6.0).default(0.0),
    MID = db().min(-60.0).max(6.0).default(0.0),
    HIGH = db().min(-60.0).max(6.0).default(0.0),
    KILL_LOW = toggle(),
    KILL_MID = toggle(),
    KILL_HIGH = toggle(),
}

static mut LP_F: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];
static mut HP_F: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];
static mut BP_LP: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];
static mut BP_HP: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];

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
        let low_gain = if ctx.param(KILL_LOW) > 0.5 { 0.0 } else { db_to_gain(ctx.param(LOW) as f64) };
        let mid_gain = if ctx.param(KILL_MID) > 0.5 { 0.0 } else { db_to_gain(ctx.param(MID) as f64) };
        let high_gain = if ctx.param(KILL_HIGH) > 0.5 { 0.0 } else { db_to_gain(ctx.param(HIGH) as f64) };

        for c in 0..ctx.channels() {
            LP_F[c].set_coeffs(BiquadCoeffs::lowpass(250.0, 0.7, sr));
            HP_F[c].set_coeffs(BiquadCoeffs::highpass(2500.0, 0.7, sr));
            BP_LP[c].set_coeffs(BiquadCoeffs::lowpass(2500.0, 0.7, sr));
            BP_HP[c].set_coeffs(BiquadCoeffs::highpass(250.0, 0.7, sr));

            for i in 0..ctx.frames() {
                let x = ctx.input(c, i) as f64;

                let low = LP_F[c].process_sample(x) * low_gain;
                let high = HP_F[c].process_sample(x) * high_gain;
                let mid_sig = BP_HP[c].process_sample(x);
                let mid = BP_LP[c].process_sample(mid_sig) * mid_gain;

                ctx.set_output(c, i, (low + mid + high) as f32);
            }
        }
    }
}
