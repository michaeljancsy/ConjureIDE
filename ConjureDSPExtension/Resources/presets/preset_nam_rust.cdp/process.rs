use conjuredsp::*;

// Fender Super Reverb 1977
// https://www.tone3000.com/tones/fender-super-reverb-1977-19
//
// To load this tone, open the Tones panel from the toolbar,
// search for "Fender Super Reverb 1977", download the
// "EQ Flat, Volume 3, sm57 and AKG 414" model, then click Run.
//
// For multiple NAM models in one preset (e.g. drive → cab cascades),
// use `nams! { DRIVE = "tone3000://...", CAB = "tone3000://..." }`
// and call `nam_process_slot(DRIVE, ...)`. See `get_docs("nam")`.
conjuredsp::nam!("tone3000://19/56");


params! {
    INPUT_GAIN = db().min(-12.0).max(12.0).default(0.0),
    MIX = mix().default(1.0),
}

/// NAM Tone — Neural Amp Modeler preset.
///
/// Runs a downloaded NAM tone model (guitar amp, pedal, or full rig
/// emulation) on the input signal. Use the Tones browser to download
/// models from tone3000.com, then update the nam!() path above.
process! { ctx =>
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
