// Clean Boost — transparent signal boost with tone shaping.
//
// A clean volume boost with treble and bass EQ controls. Adds
// no distortion of its own — just pushes level into whatever
// comes next. With treble boosted, cuts through a mix; with bass
// boosted, thickens the tone. The most transparent guitar pedal
// concept: push a tube amp harder, stack before overdrive, or
// use as a solo volume lift. Think EP Booster, Xotic RC Booster.
//
// Params:
//   boost:  Volume boost (0-25 dB)
//   treble: High frequency adjustment (-6 to +6 dB)
//   bass:   Low frequency adjustment (-6 to +6 dB)

use conjuredsp::*;
setup!();

params! {
    BOOST = db().min(0.0).max(25.0).default(10.0),
    TREBLE = db().min(-6.0).max(6.0).default(3.0),
    BASS = db().min(-6.0).max(6.0).default(0.0),
}

static mut LS: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];
static mut HS: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];

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
        let boost = db_to_gain(ctx.param(BOOST) as f64);
        let treble_db = ctx.param(TREBLE) as f64;
        let bass_db = ctx.param(BASS) as f64;

        let ls_coeffs = BiquadCoeffs::lowshelf(250.0, 0.7, bass_db, sr);
        let hs_coeffs = BiquadCoeffs::highshelf(3000.0, 0.7, treble_db, sr);

        for ch in 0..ctx.channels() {
            LS[ch].set_coeffs(ls_coeffs);
            HS[ch].set_coeffs(hs_coeffs);

            for i in 0..ctx.frames() {
                let mut x = ctx.input(ch, i) as f64 * boost;
                x = LS[ch].process_sample(x);
                x = HS[ch].process_sample(x);
                ctx.set_output(ch, i, x as f32);
            }
        }
    }
}
