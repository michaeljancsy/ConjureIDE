// Morphine Drip — narcotic haze, time slowing between heartbeats.
//
// Slow 0.5 Hz "drip" envelope (triangle LFO squared → sin²-like pulsing) as
// the primary amplitude gate → narcotic slow pitch drift (single dual-tap
// delay modulated by a 0.23 Hz sine LFO) → soft tanh saturation → long
// lowpass-feedback delay (380 ms, dark feedback path) → final mix.
//
// Distinct from Broken Fax Lullaby: single slow drip instead of coprime
// square-gate chorus; narcotic mood vs broken-fax mechanical clatter. The
// drip envelope IS the sound rather than a side stage.
//
// Params:
//   DRIP  (pct) — drip envelope depth
//   HAZE  (pct) — tanh saturation drive
//   DRIFT (pct) — slow pitch drift depth
//   BLEED (pct) — feedback delay amount
//   MIX         — wet/dry blend

use conjuredsp::*;
setup!();

params! {
    DRIP = pct().default(70.0),
    HAZE = pct().default(50.0),
    DRIFT = pct().default(45.0),
    BLEED = pct().default(60.0),
    MIX = mix().default(0.55),
}

const MAX_DL: usize = 60000;

const DRIP_HZ: f64 = 0.5;
const DRIFT_HZ: f64 = 0.23;
const DELAY_MS: f64 = 380.0;
const DRIFT_BASE_MS: f64 = 15.0;

static mut DRIP_LFO: Lfo = Lfo::new();
static mut DRIFT_LFO: Lfo = Lfo::new();
static mut DRIFT_DL: [DelayLine<MAX_DL>; 2] = [DelayLine::new(); 2];
static mut DELAY_DL: [DelayLine<MAX_DL>; 2] = [DelayLine::new(); 2];
static mut DELAY_LP: [Biquad; 2] = [Biquad::new(); 2];
static mut DELAY_FB: [f64; 2] = [0.0; 2];

#[no_mangle]
pub extern "C" fn process(
    input: *const f32, output: *mut f32,
    channels: i32, frame_count: i32, sample_rate: f32,
) {
    let ctx = ctx(input, output, channels, frame_count, sample_rate);
    let sr = ctx.sample_rate() as f64;

    unsafe {
        let drip = ctx.param(DRIP) as f64 / 100.0;
        let haze = ctx.param(HAZE) as f64 / 100.0;
        let drift = ctx.param(DRIFT) as f64 / 100.0;
        let bleed = ctx.param(BLEED) as f64 / 100.0;
        let mx = ctx.param(MIX) as f64;

        DRIP_LFO.init(sr, DRIP_HZ);
        DRIP_LFO.set_waveform(Waveform::Triangle);
        DRIFT_LFO.init(sr, DRIFT_HZ);

        let delay_lpc = BiquadCoeffs::lowpass(1200.0, 0.707, sr);
        let nch = ctx.channels().min(2);
        for ch in 0..nch {
            DELAY_LP[ch].set_coeffs(delay_lpc);
        }

        let drip_depth = 0.85 * drip;
        let drive = 1.0 + 4.0 * haze;
        let drift_base = DRIFT_BASE_MS * 0.001 * sr;
        let drift_depth = (2.0 + 8.0 * drift) * 0.001 * sr;
        let delay_d = DELAY_MS * 0.001 * sr;
        let delay_fb_amt = 0.55 + 0.30 * bleed;

        for f in 0..ctx.frames() {
            let tri = DRIP_LFO.tick();
            let pulse = 0.5 + 0.5 * tri;
            let drip_env = (1.0 - drip_depth) + drip_depth * pulse * pulse;

            let drift_val = DRIFT_LFO.tick();
            let mut dd = drift_base + drift_val * drift_depth;
            if dd < 1.0 {
                dd = 1.0;
            }

            for ch in 0..nch {
                let dry = ctx.input(ch, f) as f64;

                let gated = dry * drip_env;

                DRIFT_DL[ch].write(gated as f32);
                let drifted = DRIFT_DL[ch].read(dd) as f64;

                let sat = (drifted * drive).tanh() / drive;

                let f_in = DELAY_LP[ch].process_sample(DELAY_FB[ch]);
                DELAY_DL[ch].write((sat + delay_fb_amt * f_in) as f32);
                DELAY_FB[ch] = DELAY_DL[ch].read(delay_d) as f64;

                let wet = sat + DELAY_FB[ch] * 0.7;
                ctx.set_output(ch, f, (dry * (1.0 - mx) + wet * mx) as f32);
            }
        }
    }
}
