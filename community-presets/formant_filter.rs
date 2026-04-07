// Formant Filter — vowel-shaping resonant filter.

use conjuredsp::*;
setup!();

params! {
    VOWEL = choice(&["A", "E", "I", "O", "U"]),
    RESONANCE = param(1.0, 20.0).unit("Q").default(8.0),
    SHIFT = param(-12.0, 12.0).unit("st").default(0.0),
}

static mut FILTERS: [[Biquad; 3]; MAX_CH] = [[Biquad::new(); 3]; MAX_CH];

// Formant frequencies (F1, F2, F3) for each vowel
const VOWEL_FORMANTS: [[f64; 3]; 5] = [
    [800.0, 1200.0, 2500.0],   // A
    [350.0, 2000.0, 2800.0],   // E
    [270.0, 2300.0, 3000.0],   // I
    [450.0, 800.0, 2500.0],    // O
    [325.0, 700.0, 2500.0],    // U
];

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
        let vowel_idx = (ctx.param(VOWEL) as usize).min(4);
        let q = ctx.param(RESONANCE) as f64;
        let shift_st = ctx.param(SHIFT) as f64;

        let formants = VOWEL_FORMANTS[vowel_idx];
        let shift_ratio = 2.0_f64.powf(shift_st / 12.0);

        for c in 0..ctx.channels() {
            for f_idx in 0..3 {
                let freq = (formants[f_idx] * shift_ratio).max(50.0).min(sr * 0.45);
                let coeffs = BiquadCoeffs::bandpass(freq, q, sr);
                FILTERS[c][f_idx].set_coeffs(coeffs);
            }

            for i in 0..ctx.frames() {
                let x = ctx.input(c, i) as f64;
                let mut y = 0.0;
                for f_idx in 0..3 {
                    y += FILTERS[c][f_idx].process_sample(x);
                }
                ctx.set_output(c, i, (y * 0.4) as f32);
            }
        }
    }
}
