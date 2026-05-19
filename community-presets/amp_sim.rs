// Amp Sim — basic tube amplifier model.
//
// Models three amplifier channels: Clean (slight compression),
// Crunch (edge of breakup), and Lead (heavy saturation). Uses
// pre-EQ shaping, asymmetric soft clipping, and post-EQ tone
// control. Not a cabinet sim — pair with the cab_sim preset
// for a full amp+cab chain. Great for guitar and bass direct
// recording.
//
// Params:
//   channel: Amp channel (Clean/Crunch/Lead)
//   gain:    Preamp gain (0-40 dB)
//   tone:    Post-distortion brightness (0-1)
//   volume:  Master volume (-20 to +6 dB)

use conjuredsp::*;
setup!();

params! {
    CHANNEL = choice(&["Clean", "Crunch", "Lead"]).default(1.0),
    GAIN = db().min(0.0).max(40.0).default(15.0),
    TONE = param(0.0, 1.0).default(0.5),
    VOLUME = db().min(-20.0).max(6.0).default(0.0),
}

static mut HP: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];
static mut MID: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];
static mut LP: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];

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
        let channel = ctx.param(CHANNEL) as i32;
        let gain_db = ctx.param(GAIN) as f64;
        let tone = ctx.param(TONE) as f64;
        let volume_db = ctx.param(VOLUME) as f64;

        let mut gain = db_to_gain(gain_db);
        let volume = db_to_gain(volume_db);

        // Channel-specific EQ and gain
        let mid_boost: f64;
        if channel == 0 {
            // Clean
            gain *= 0.3;
            mid_boost = 3.0;
        } else if channel == 1 {
            // Crunch
            gain *= 1.0;
            mid_boost = 5.0;
        } else {
            // Lead
            gain *= 3.0;
            mid_boost = 8.0;
        }

        let lp_freq = 3000.0 + tone * 7000.0;

        let hp_coeffs = BiquadCoeffs::highpass(80.0, 0.7, sr);
        let mid_coeffs = BiquadCoeffs::peak(800.0, 1.5, mid_boost, sr);
        let lp_coeffs = BiquadCoeffs::lowpass(lp_freq, 0.7, sr);

        for ch in 0..ctx.channels() {
            HP[ch].set_coeffs(hp_coeffs);
            MID[ch].set_coeffs(mid_coeffs);
            LP[ch].set_coeffs(lp_coeffs);

            for i in 0..ctx.frames() {
                let mut x = ctx.input(ch, i) as f64;

                // Input stage
                x = HP[ch].process_sample(x);
                x = MID[ch].process_sample(x);
                x *= gain;

                // Tube-like asymmetric clipping
                let y: f64;
                if x >= 0.0 {
                    y = x.tanh();
                } else {
                    y = (x * 1.3).tanh() * 0.8;
                }

                // Tone stack
                let y = LP[ch].process_sample(y);

                ctx.set_output(ch, i, (y * volume) as f32);
            }
        }
    }
}
