// Rusted Carousel — a derelict fairground organ playing a lopsided waltz.
//
// 5-voice calliope chorus (prime-spaced 9 / 13 / 17 / 23 / 29 ms base
// delays, each modulated by its own 0.17–0.41 Hz LFO — ±25¢-ish detune) →
// waltz amplitude LFO (1.2 Hz triangle shaped as |tri| to pulse in 3s) →
// pipe-pitch feedback comb at 110 Hz (~9.09 ms) → asymmetric tube-style
// tanh saturation → final mix.
//
// Distinct from Broken Fax Lullaby: metered waltz LFO rather than coprime
// square gating; detuned-organ texture. Distinct from Underwater Spy: the
// chorus itself is the rust/character, not a lush doubling effect.
//
// Params:
//   CALLIOPE (pct) — chorus depth
//   WALTZ    (pct) — waltz amplitude modulation depth
//   ORGAN    (pct) — pipe comb feedback
//   TUBE     (pct) — asymmetric tanh drive
//   MIX            — wet/dry blend

use conjuredsp::*;
setup!();

params! {
    CALLIOPE = pct().default(60.0),
    WALTZ = pct().default(55.0),
    ORGAN = pct().default(50.0),
    TUBE = pct().default(45.0),
    MIX = mix().default(0.55),
}

const MAX_DL: usize = 10000;

const CHORUS_MS: [f64; 5] = [9.0, 13.0, 17.0, 23.0, 29.0];
const CHORUS_LFO_HZ: [f64; 5] = [0.17, 0.23, 0.29, 0.37, 0.41];
const WALTZ_HZ: f64 = 1.2;
const PIPE_HZ: f64 = 110.0;

static mut CHORUS_DL: [[DelayLine<MAX_DL>; 5]; 2] = [[DelayLine::new(); 5]; 2];
static mut CHORUS_LFO: [Lfo; 5] = [Lfo::new(); 5];
static mut WALTZ_LFO: Lfo = Lfo::new();
static mut PIPE_DL: [DelayLine<MAX_DL>; 2] = [DelayLine::new(); 2];
static mut PIPE_FB: [f64; 2] = [0.0; 2];
static mut PIPE_LP: [Biquad; 2] = [Biquad::new(); 2];

#[no_mangle]
pub extern "C" fn process(
    input: *const f32, output: *mut f32,
    channels: i32, frame_count: i32, sample_rate: f32,
) {
    let ctx = ctx(input, output, channels, frame_count, sample_rate);
    let sr = ctx.sample_rate() as f64;

    unsafe {
        let calliope = ctx.param(CALLIOPE) as f64 / 100.0;
        let waltz = ctx.param(WALTZ) as f64 / 100.0;
        let organ = ctx.param(ORGAN) as f64 / 100.0;
        let tube = ctx.param(TUBE) as f64 / 100.0;
        let mx = ctx.param(MIX) as f64;

        let pipe_lpc = BiquadCoeffs::lowpass(2800.0, 0.707, sr);

        for k in 0..5 {
            CHORUS_LFO[k].init(sr, CHORUS_LFO_HZ[k]);
        }
        WALTZ_LFO.init(sr, WALTZ_HZ);
        WALTZ_LFO.set_waveform(Waveform::Triangle);

        let nch = ctx.channels().min(2);
        for ch in 0..nch {
            PIPE_LP[ch].set_coeffs(pipe_lpc);
        }

        let chorus_base: [f64; 5] = [
            CHORUS_MS[0] * 0.001 * sr,
            CHORUS_MS[1] * 0.001 * sr,
            CHORUS_MS[2] * 0.001 * sr,
            CHORUS_MS[3] * 0.001 * sr,
            CHORUS_MS[4] * 0.001 * sr,
        ];
        let chorus_depth = (0.8 + 1.8 * calliope) * 0.001 * sr;
        let waltz_depth = 0.65 * waltz;
        let pipe_d = (1.0 / PIPE_HZ) * sr;
        let pipe_fb_amt = 0.50 + 0.40 * organ;

        let drive_pos = 1.0 + 3.0 * tube;
        let drive_neg = 1.0 + 1.5 * tube;

        let chorus_gain: f64 = 1.0 / 5.0;

        for f in 0..ctx.frames() {
            let cm: [f64; 5] = [
                CHORUS_LFO[0].tick(),
                CHORUS_LFO[1].tick(),
                CHORUS_LFO[2].tick(),
                CHORUS_LFO[3].tick(),
                CHORUS_LFO[4].tick(),
            ];
            let w_tri = WALTZ_LFO.tick();
            let waltz_mod = (1.0 - waltz_depth) + waltz_depth * w_tri.abs();

            for ch in 0..nch {
                let dry = ctx.input(ch, f) as f64;

                let mut chorus_sum: f64 = 0.0;
                for k in 0..5 {
                    let mut d = chorus_base[k] + cm[k] * chorus_depth;
                    if d < 1.0 {
                        d = 1.0;
                    }
                    CHORUS_DL[ch][k].write(dry as f32);
                    chorus_sum += CHORUS_DL[ch][k].read(d) as f64;
                }
                chorus_sum *= chorus_gain;

                let pulsed = chorus_sum * waltz_mod;

                let f_in = PIPE_LP[ch].process_sample(PIPE_FB[ch]);
                PIPE_DL[ch].write((pulsed + pipe_fb_amt * f_in) as f32);
                PIPE_FB[ch] = PIPE_DL[ch].read(pipe_d) as f64;

                let x = pulsed + PIPE_FB[ch] * 0.6;
                let wet = if x >= 0.0 {
                    (x * drive_pos).tanh() / drive_pos
                } else {
                    (x * drive_neg).tanh() / drive_neg
                };

                ctx.set_output(ch, f, (dry * (1.0 - mx) + wet * mx) as f32);
            }
        }
    }
}
