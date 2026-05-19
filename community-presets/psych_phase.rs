// Psychedelic Phaser — deep, swirling phase shifting.
//
// Many stages and high feedback for maximum psychedelic swirl. The
// signature effect of 60s/70s psychedelic rock pushed into the cosmic.

use conjuredsp::*;
setup!();

params! {
    RATE = param(0.05, 5.0).unit("Hz").default(0.3),
    DEPTH = param(0.0, 1.0).default(0.9),
    FEEDBACK = param(-0.9, 0.9).default(0.7),
    STAGES = param(4.0, 12.0).default(8.0),
    MIX = mix().default(0.7),
}

static mut PHASE: f64 = 0.0;
static mut AP: [[Biquad; 12]; MAX_CH] = [[Biquad::new(); 12]; MAX_CH];
static mut FB_SAMPLE: [f64; MAX_CH] = [0.0; MAX_CH];

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
        let rate = ctx.param(RATE) as f64;
        let depth = ctx.param(DEPTH) as f64;
        let feedback = ctx.param(FEEDBACK) as f64;
        let n_stages = ctx.param(STAGES) as usize;
        let wet_mix = ctx.param(MIX) as f64;

        let two_pi = 2.0 * core::f64::consts::PI;

        for i in 0..ctx.frames() {
            // Sine LFO for sweep
            let lfo = (two_pi * PHASE).sin();
            let sweep = 0.5 + 0.5 * lfo * depth;

            // Sweep frequency range (logarithmic)
            let min_f: f64 = 100.0;
            let max_f: f64 = 4000.0;
            let mut sweep_freq = min_f * (max_f / min_f).powf(sweep);
            if sweep_freq > sr * 0.45 {
                sweep_freq = sr * 0.45;
            }

            for ch in 0..ctx.channels() {
                let mut x = ctx.input(ch, i) as f64 + FB_SAMPLE[ch] * feedback;

                let mut y = x;
                for s in 0..n_stages {
                    // Stagger each stage slightly for richer effect
                    let n_stages_m1 = if n_stages > 1 { (n_stages - 1) as f64 } else { 1.0 };
                    let mut stage_freq = sweep_freq * (0.8 + 0.4 * s as f64 / n_stages_m1);
                    if stage_freq > sr * 0.45 {
                        stage_freq = sr * 0.45;
                    }
                    let coeffs = BiquadCoeffs::allpass(stage_freq, 0.5, sr);
                    AP[ch][s].set_coeffs(coeffs);
                    y = AP[ch][s].process_sample(y);
                }

                FB_SAMPLE[ch] = y;

                ctx.set_output(
                    ch,
                    i,
                    (ctx.input(ch, i) as f64 * (1.0 - wet_mix) + y * wet_mix) as f32,
                );
            }

            PHASE = (PHASE + rate / sr) % 1.0;
        }
    }
}
