// Proximity Bass -- bass proximity effect enhancement.
//
// Simulates the bass boost that occurs when a microphone is placed
// very close to a sound source (the proximity effect). A low shelf
// adds warmth and weight, while a gentle peak in the low-mids adds body.

use conjuredsp::*;
setup!();

params! {
    PROXIMITY = db(0.0, 12.0).default(6.0),
    FREQUENCY = freq().min(80.0).max(300.0).default(150.0),
    WARMTH = db(0.0, 6.0).default(2.0),
}

static mut LS: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];
static mut PEAK_F: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];

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
        let proximity_db = ctx.param(PROXIMITY) as f64;
        let freq_hz = ctx.param(FREQUENCY) as f64;
        let warmth_db = ctx.param(WARMTH) as f64;

        for ch in 0..ctx.channels() {
            LS[ch].set_coeffs(BiquadCoeffs::lowshelf(
                freq_hz, 0.7, proximity_db, sr,
            ));
            PEAK_F[ch].set_coeffs(BiquadCoeffs::peak(
                freq_hz * 2.0, 1.0, warmth_db, sr,
            ));

            for i in 0..ctx.frames() {
                let x = ctx.input(ch, i);
                let x = LS[ch].process_sample(x);
                let x = PEAK_F[ch].process_sample(x);
                ctx.set_output(ch, i, x);
            }
        }
    }
}
