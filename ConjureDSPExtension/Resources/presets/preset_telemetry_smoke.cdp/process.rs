// Telemetry smoke test — proves the DSP→UI scalar telemetry channel.
//
// DSP: scales the input signal by `drive`, soft-clips, and runs a simple
// per-block peak detector + slow envelope follower over the input.
//
// Telemetry slots (read by the UI via `frame.telemetry.*`):
//   PEAK_DB     — instantaneous block peak in dB. Same idea as
//                 frame.peakIn but expressed in dB so the UI doesn't
//                 need to convert. Reactive: jumps on transients.
//   ENVELOPE_DB — slow-attack/release envelope in dB. CANNOT be
//                 reconstructed from the existing audio.onFrame
//                 payload — it's purely internal DSP state, which is
//                 the whole point of telemetry.

use conjuredsp::*;
setup!();

params! {
    DRIVE = param(1.0, 10.0).default(1.0).unit("x"),
}

telemetry! {
    PEAK_DB     = scalar_telemetry().unit("dB"),
    ENVELOPE_DB = scalar_telemetry().unit("dB"),
}

// Persistent envelope state. f32 here is fine; the smoke preset doesn't
// need the f64 precision of the production compressor.
static mut ENVELOPE: f32 = 0.0;

#[no_mangle]
pub extern "C" fn process(
    input: *const f32,
    output: *mut f32,
    channel_count: i32,
    frame_count: i32,
    sample_rate: f32,
) {
    let ctx = ctx(input, output, channel_count, frame_count, sample_rate);
    let drive = ctx.param(DRIVE).max(1.0);

    // Block peak (linear) across all channels — used both to drive the
    // envelope follower and to publish PEAK_DB.
    let mut block_peak: f32 = 0.0;

    // 50ms attack, 200ms release smoothing. Coefficients computed once
    // per block from the live sample rate.
    let attack_coeff = (-1.0 / (0.050 * sample_rate)).exp();
    let release_coeff = (-1.0 / (0.200 * sample_rate)).exp();

    for f in 0..ctx.frames() {
        for c in 0..ctx.channels() {
            let x = ctx.input(c, f);
            let abs = x.abs();
            if abs > block_peak {
                block_peak = abs;
            }

            // Per-sample envelope follower (linked across channels —
            // last channel wins for the per-sample update, fine for a
            // smoke test). soft_clip imported from conjuredsp::dsp.
            unsafe {
                let target = abs * drive;
                let coeff = if target > ENVELOPE { attack_coeff } else { release_coeff };
                ENVELOPE = target + coeff * (ENVELOPE - target);
            }

            ctx.set_output(c, f, soft_clip(x as f64, drive as f64) as f32);
        }
    }

    // dB conversion. -120 floor keeps the UI from drawing log(0).
    fn lin_to_db(x: f32) -> f32 {
        if x <= 1e-6 { -120.0 } else { 20.0 * x.log10() }
    }

    let env = unsafe { ENVELOPE };
    ctx.set_telemetry_scalar(PEAK_DB, lin_to_db(block_peak));
    ctx.set_telemetry_scalar(ENVELOPE_DB, lin_to_db(env));
}
