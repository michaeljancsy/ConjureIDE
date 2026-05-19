// Multi-Band Compressor — 3-band independent compression.

use conjuredsp::*;
setup!();

params! {
    LOW_THRESH = db().min(-40.0).max(0.0).default(-20.0),
    MID_THRESH = db().min(-40.0).max(0.0).default(-18.0),
    HIGH_THRESH = db().min(-40.0).max(0.0).default(-15.0),
    RATIO = ratio().min(2.0).max(20.0).default(4.0),
    ATTACK = time_ms().min(0.5).max(50.0).default(5.0),
    RELEASE = time_ms().min(10.0).max(500.0).default(80.0),
}

static mut LP_F: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];
static mut HP_F: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];
static mut BP_LP: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];
static mut BP_HP: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];
static mut ENV: [f64; 3] = [0.0; 3];

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
        let thresholds = [
            db_to_gain(ctx.param(LOW_THRESH) as f64),
            db_to_gain(ctx.param(MID_THRESH) as f64),
            db_to_gain(ctx.param(HIGH_THRESH) as f64),
        ];
        let comp_ratio = ctx.param(RATIO) as f64;
        let att = smooth_coeff(ctx.param(ATTACK) as f64, sr);
        let rel = smooth_coeff(ctx.param(RELEASE) as f64, sr);

        for c in 0..ctx.channels() {
            LP_F[c].set_coeffs(BiquadCoeffs::lowpass(250.0, 0.7, sr));
            HP_F[c].set_coeffs(BiquadCoeffs::highpass(2500.0, 0.7, sr));
            BP_LP[c].set_coeffs(BiquadCoeffs::lowpass(2500.0, 0.7, sr));
            BP_HP[c].set_coeffs(BiquadCoeffs::highpass(250.0, 0.7, sr));
        }

        for i in 0..ctx.frames() {
            for c in 0..ctx.channels() {
                let x = ctx.input(c, i) as f64;

                let bands = [
                    LP_F[c].process_sample(x),
                    BP_LP[c].process_sample(BP_HP[c].process_sample(x)),
                    HP_F[c].process_sample(x),
                ];

                let mut out = 0.0;
                for b in 0..3 {
                    let level = bands[b].abs();

                    if level > ENV[b] {
                        ENV[b] = att * ENV[b] + (1.0 - att) * level;
                    } else {
                        ENV[b] = rel * ENV[b] + (1.0 - rel) * level;
                    }

                    let gain = if ENV[b] > thresholds[b] {
                        let db_over = 20.0 * (ENV[b] / thresholds[b] + 1e-30).log10();
                        let db_red = db_over * (1.0 - 1.0 / comp_ratio);
                        10.0_f64.powf(-db_red / 20.0)
                    } else {
                        1.0
                    };

                    out += bands[b] * gain;
                }

                ctx.set_output(c, i, out as f32);
            }
        }
    }
}
