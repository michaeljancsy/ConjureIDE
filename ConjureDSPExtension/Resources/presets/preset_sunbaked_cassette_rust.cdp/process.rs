// Sun-Baked Cassette — cassette tape left in the sun for 30 years.
//
// Wow + flutter modulated delay → frequency-dependent + asymmetric tanh
// saturation → tone shaping shelves → print-through pre-echo → tape echo
// (LP in feedback) → head-wear feedback comb → final mix.
//
// Params:
//   WOW     (ms)  — slow pitch drift depth (0–6)
//   FLUTTER (ms)  — fast warble depth (0–3)
//   WEAR    (pct) — drives saturation amount, 0=clean / 100=destroyed
//   TONE    (pct) — high-frequency rolloff amount (0=bright / 100=dull)
//   MIX           — wet/dry blend

use conjuredsp::*;
setup!();

params! {
    WOW = time_ms().min(0.0).max(6.0).default(3.0),
    FLUTTER = time_ms().min(0.0).max(3.0).default(1.2),
    WEAR = pct().default(45.0),
    TONE = pct().default(50.0),
    MIX = mix().default(0.6),
}

const MAX_DL: usize = 24000;
const WF_BASE_MS: f64 = 8.0;
const PRINT_MS: f64 = 150.0;
const ECHO_MS: f64 = 280.0;
const COMB_MS: f64 = 0.7;

static mut WF: [DelayLine<MAX_DL>; 2] = [DelayLine::new(); 2];
static mut PRE_HS: [Biquad; 2] = [Biquad::new(); 2];
static mut DE_HS: [Biquad; 2] = [Biquad::new(); 2];
static mut LO_SH: [Biquad; 2] = [Biquad::new(); 2];
static mut HI_SH: [Biquad; 2] = [Biquad::new(); 2];
static mut PRINT_DL: [DelayLine<MAX_DL>; 2] = [DelayLine::new(); 2];
static mut PRINT_LP: [Biquad; 2] = [Biquad::new(); 2];
static mut ECHO_DL: [DelayLine<MAX_DL>; 2] = [DelayLine::new(); 2];
static mut ECHO_LP: [Biquad; 2] = [Biquad::new(); 2];
static mut ECHO_FB: [f64; 2] = [0.0; 2];
static mut COMB_DL: [DelayLine<MAX_DL>; 2] = [DelayLine::new(); 2];
static mut COMB_FB: [f64; 2] = [0.0; 2];
static mut LFO_WOW: Lfo = Lfo::new();
static mut LFO_FLUTTER: Lfo = Lfo::new();

#[no_mangle]
pub extern "C" fn process(
    input: *const f32, output: *mut f32,
    channel_count: i32, frame_count: i32, sample_rate: f32,
) {
    let ctx = ctx(input, output, channel_count, frame_count, sample_rate);
    let sr = ctx.sample_rate() as f64;

    unsafe {
        let wow_ms = ctx.param(WOW) as f64;
        let flutter_ms = ctx.param(FLUTTER) as f64;
        let wear = ctx.param(WEAR) as f64 / 100.0;
        let tone = ctx.param(TONE) as f64 / 100.0;
        let mx = ctx.param(MIX) as f64;

        let pre_hsc = BiquadCoeffs::highshelf(5000.0, 0.707, 6.0, sr);
        let de_hsc = BiquadCoeffs::highshelf(5000.0, 0.707, -9.0, sr);
        let lo_shc = BiquadCoeffs::lowshelf(120.0, 0.707, 3.0, sr);
        let hi_shc = BiquadCoeffs::highshelf(8000.0, 0.707, -12.0 * tone, sr);
        let print_lpc = BiquadCoeffs::lowpass(1500.0, 0.707, sr);
        let echo_lpc = BiquadCoeffs::lowpass(3000.0, 0.707, sr);

        LFO_WOW.init(sr, 0.5);
        LFO_FLUTTER.init(sr, 7.0);

        let nch = ctx.channels().min(2);
        for ch in 0..nch {
            PRE_HS[ch].set_coeffs(pre_hsc);
            DE_HS[ch].set_coeffs(de_hsc);
            LO_SH[ch].set_coeffs(lo_shc);
            HI_SH[ch].set_coeffs(hi_shc);
            PRINT_LP[ch].set_coeffs(print_lpc);
            ECHO_LP[ch].set_coeffs(echo_lpc);
        }

        let drive_pos = 1.0 + wear * 2.5;
        let drive_neg = 1.0 + wear * 1.6;

        let base_d = WF_BASE_MS * 0.001 * sr;
        let wow_depth = wow_ms * 0.001 * sr;
        let flutter_depth = flutter_ms * 0.001 * sr;
        let print_d = PRINT_MS * 0.001 * sr;
        let echo_d = ECHO_MS * 0.001 * sr;
        let comb_d = (COMB_MS * 0.001 * sr).max(1.0);

        let print_gain: f64 = 0.04;
        let echo_fb_amt: f64 = 0.4;
        let comb_fb_amt: f64 = 0.35;

        for f in 0..ctx.frames() {
            let wlfo = LFO_WOW.tick();
            let flfo = LFO_FLUTTER.tick();
            let d = (base_d + wlfo * wow_depth + flfo * flutter_depth).max(1.0);

            for ch in 0..nch {
                let dry = ctx.input(ch, f) as f64;

                // Stage A: wow + flutter modulated delay
                WF[ch].write(dry as f32);
                let mut x = WF[ch].read(d) as f64;

                // Stage B: pre-emphasis highshelf
                x = PRE_HS[ch].process_sample(x);

                // Stage C: asymmetric tanh saturation
                if x > 0.0 {
                    x = (x * drive_pos).tanh();
                } else {
                    x = (x * drive_neg).tanh();
                }

                // Stage D: de-emphasis highshelf
                x = DE_HS[ch].process_sample(x);

                // Stage E: tone shaping (warmth + HF rolloff)
                x = LO_SH[ch].process_sample(x);
                x = HI_SH[ch].process_sample(x);

                // Stage F: print-through pre-echo (lowpassed delayed dry)
                PRINT_DL[ch].write(dry as f32);
                let mut print_tap = PRINT_DL[ch].read(print_d) as f64;
                print_tap = PRINT_LP[ch].process_sample(print_tap);
                x = x + print_tap * print_gain;

                // Stage G: tape echo (LP in feedback)
                let eflt = ECHO_LP[ch].process_sample(ECHO_FB[ch]);
                ECHO_DL[ch].write((x + echo_fb_amt * eflt) as f32);
                ECHO_FB[ch] = ECHO_DL[ch].read(echo_d) as f64;
                x = x + 0.5 * ECHO_FB[ch];

                // Stage H: head-wear feedback comb
                COMB_DL[ch].write((x + comb_fb_amt * COMB_FB[ch]) as f32);
                COMB_FB[ch] = COMB_DL[ch].read(comb_d) as f64;
                x = x + 0.3 * COMB_FB[ch];

                ctx.set_output(ch, f, (dry * (1.0 - mx) + x * mx) as f32);
            }
        }
    }
}
