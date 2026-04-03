use conjuredsp::*;

setup!();

// Replace "tone3000://TONE_ID/MODEL_ID" with an actual path from list_tones.
nam!("tone3000://TONE_ID/MODEL_ID");

params! {
    INPUT_GAIN = db().min(-12.0).max(12.0).default(0.0),
    MIX = mix().default(1.0),
}

/// NAM Tone — Neural Amp Modeler preset.
///
/// Runs a downloaded NAM tone model (guitar amp, pedal, or full rig
/// emulation) on the input signal. Use the Tones browser to download
/// models from tone3000.com, then update the nam!() path above.
#[no_mangle]
pub extern "C" fn process(
    input: *const f32,
    output: *mut f32,
    channels: i32,
    frame_count: i32,
    sample_rate: f32,
) {
    let ctx = ctx(input, output, channels, frame_count, sample_rate);
    unsafe {
        let gain = db_to_gain(ctx.param(INPUT_GAIN) as f64) as f32;
        let mix_val = ctx.param(MIX);
        for c in 0..ctx.channels() {
            let n = ctx.frames();
            for i in 0..n {
                NAM_IN[i] = ctx.input(c, i) * gain;
            }
            nam_process(&NAM_IN[..n], &mut NAM_OUT[..n], c);
            for i in 0..n {
                ctx.set_output(
                    c,
                    i,
                    ctx.input(c, i) * (1.0 - mix_val) + NAM_OUT[i] * mix_val,
                );
            }
        }
    }
}
