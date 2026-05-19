// Vocal Air -- high-frequency presence and "air" boost.
//
// Adds the elusive "air" quality to vocals -- that breathy,
// open, expensive-sounding top end. A high shelf boosts the
// extreme highs while a presence peak adds clarity in 3-5 kHz.

use conjuredsp::*;
setup!();

params! {
    AIR = db(0.0, 12.0).default(6.0),
    FREQUENCY = freq().min(6000.0).max(16000.0).default(10000.0),
    PRESENCE = db(-6.0, 6.0).default(2.0),
}

static mut HS: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];
static mut PEAK: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];

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
        let air_db = ctx.param(AIR) as f64;
        let air_freq = ctx.param(FREQUENCY) as f64;
        let presence_db = ctx.param(PRESENCE) as f64;

        for ch in 0..ctx.channels() {
            HS[ch].set_coeffs(BiquadCoeffs::highshelf(
                air_freq, 0.7, air_db, sr,
            ));
            PEAK[ch].set_coeffs(BiquadCoeffs::peak(
                4000.0, 1.5, presence_db, sr,
            ));

            for i in 0..ctx.frames() {
                let x = ctx.input(ch, i);
                let x = HS[ch].process_sample(x);
                let x = PEAK[ch].process_sample(x);
                ctx.set_output(ch, i, x);
            }
        }
    }
}
