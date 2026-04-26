// Alien Radio — alien radio signal bleeding through from another dimension.
//
// Per-channel telephony bandpass → per-channel ring modulation (L: 110 Hz,
// R: 1760 Hz alien harmonic) → heterodyne squeal feedback comb → sample-and-
// hold rate reduction → bit-depth reduction → squelch tremolo → carrier
// interference (800 Hz beating tone) → mid/side widening → final highpass → mix.
//
// Params:
//   DRIFT        (pct) — modulates carrier ring-mod offsets
//   INTERFERENCE (pct) — tremolo depth + carrier bleed amount
//   STATIC       (pct) — heterodyne squeal feedback amount
//   CRUSH        (pct) — bit-depth reduction amount, 0=clean / 100=destroyed
//   MIX                — wet/dry blend

use conjuredsp::*;
setup!();

params! {
    DRIFT = pct().default(40.0),
    INTERFERENCE = pct().default(55.0),
    STATIC = pct().default(60.0),
    CRUSH = pct().default(50.0),
    MIX = mix().default(0.6),
}

const MAX_DL: usize = 2400;

const BP_HZ: [f64; 2] = [800.0, 2400.0];
const BP_Q: f64 = 8.0;
const CARRIER_HZ: [f64; 2] = [110.0, 1760.0];
const DRIFT_LFO_HZ: f64 = 0.17;
const TREM_HZ: f64 = 11.0;
const INTERFERE_LFO_HZ: f64 = 0.3;
const INTERFERE_TONE_HZ: f64 = 800.0;

static mut BP: [Biquad; 2] = [Biquad::new(); 2];
static mut SQUEAL: [DelayLine<MAX_DL>; 2] = [DelayLine::new(); 2];
static mut SQUEAL_FB: [f64; 2] = [0.0; 2];
static mut HP: [Biquad; 2] = [Biquad::new(); 2];
static mut SH_HELD: [f64; 2] = [0.0; 2];
static mut SH_COUNT: usize = 0;
static mut LFO_DRIFT: Lfo = Lfo::new();
static mut LFO_CARRIERS: [Lfo; 2] = [Lfo::new(); 2];
static mut LFO_TREM: Lfo = Lfo::new();
static mut TREM_ENV: f64 = 1.0;
static mut LFO_INTERFERE_AMP: Lfo = Lfo::new();
static mut LFO_INTERFERE_TONE: Lfo = Lfo::new();

#[no_mangle]
pub extern "C" fn process(
    input: *const f32, output: *mut f32,
    channel_count: i32, frame_count: i32, sample_rate: f32,
) {
    let ctx = ctx(input, output, channel_count, frame_count, sample_rate);
    let sr = ctx.sample_rate() as f64;

    unsafe {
        let drift = ctx.param(DRIFT) as f64 / 100.0;
        let interference = ctx.param(INTERFERENCE) as f64 / 100.0;
        let static_amt = ctx.param(STATIC) as f64 / 100.0;
        let crush = ctx.param(CRUSH) as f64 / 100.0;
        let mx = ctx.param(MIX) as f64;

        // LFO init
        LFO_DRIFT.init(sr, DRIFT_LFO_HZ);
        LFO_CARRIERS[0].init(sr, CARRIER_HZ[0]);
        LFO_CARRIERS[1].init(sr, CARRIER_HZ[1]);
        LFO_TREM.init(sr, TREM_HZ);
        LFO_TREM.set_waveform(Waveform::Square);
        LFO_INTERFERE_AMP.init(sr, INTERFERE_LFO_HZ);
        LFO_INTERFERE_TONE.init(sr, INTERFERE_TONE_HZ);

        let nch = ctx.channels().min(2);

        // Per-channel bandpass coefficients
        for ch in 0..nch {
            let bpc = BiquadCoeffs::bandpass(BP_HZ[ch], BP_Q, sr);
            BP[ch].set_coeffs(bpc);
        }

        // Final highpass at 250 Hz (per-channel state, same coeffs)
        let hpc = BiquadCoeffs::highpass(250.0, 0.707, sr);
        for ch in 0..nch {
            HP[ch].set_coeffs(hpc);
        }

        // Heterodyne squeal: delay = period of carrier frequency (per channel)
        let squeal_d = [
            (sr / CARRIER_HZ[0]).max(1.0),
            (sr / CARRIER_HZ[1]).max(1.0),
        ];

        // Bit-crush levels: 3 bits at crush=1, 12 bits at crush=0
        let bits = 12.0 - 9.0 * crush;
        let levels = (2.0_f64).powf(bits);
        let inv_levels = 1.0 / levels;

        // Sample-and-hold period: 1 → 6 samples
        let sh_period = ((1.0 + 5.0 * crush) as usize).max(1);

        // Squelch tremolo smoothing (12 ms one-pole)
        let trem_alpha = (-1.0_f64 / (0.012 * sr)).exp();
        let one_minus_alpha = 1.0 - trem_alpha;
        let trem_depth = interference * 0.6;

        // Heterodyne feedback amount (capped at 0.85 for parity safety)
        let squeal_fb_amt = 0.85 * static_amt;

        // Carrier interference (-18 dB · interference)
        let interfere_gain = 0.126 * interference;

        let mut wet: [f64; 2] = [0.0; 2];

        for f in 0..ctx.frames() {
            let d_lfo = LFO_DRIFT.tick();
            let car0 = LFO_CARRIERS[0].tick();
            let car1 = LFO_CARRIERS[1].tick();
            let trem = (LFO_TREM.tick() + 1.0) * 0.5;
            let ia = LFO_INTERFERE_AMP.tick();
            let it = LFO_INTERFERE_TONE.tick();

            TREM_ENV = trem_alpha * TREM_ENV + one_minus_alpha * trem;
            let trem_gain = 1.0 - trem_depth * (1.0 - TREM_ENV);

            let update_held = (SH_COUNT % sh_period) == 0;
            SH_COUNT += 1;

            let interfere = it * (0.5 + 0.5 * ia) * interfere_gain;

            let car_mod0 = car0 * (1.0 + drift * 0.3 * d_lfo);
            let car_mod1 = car1 * (1.0 + drift * 0.3 * d_lfo);
            let car = [car_mod0, car_mod1];

            for ch in 0..nch {
                let dry = ctx.input(ch, f) as f64;

                // Stage A: per-channel bandpass
                let mut x = BP[ch].process_sample(dry);

                // Stage B: per-channel ring modulation
                x = x * car[ch];

                // Stage C: heterodyne squeal feedback comb
                SQUEAL[ch].write((x + squeal_fb_amt * SQUEAL_FB[ch]) as f32);
                SQUEAL_FB[ch] = SQUEAL[ch].read(squeal_d[ch]) as f64;
                x = x + 0.5 * SQUEAL_FB[ch];

                // Stage D: sample-and-hold rate reduction
                if update_held {
                    SH_HELD[ch] = x;
                }
                let mut sig = SH_HELD[ch];

                // Stage E: bit-depth reduction
                sig = (sig * levels + 0.5).floor() * inv_levels;

                // Stage F: squelch tremolo
                sig = sig * trem_gain;

                // Stage G: carrier interference bleed
                sig = sig + interfere;

                wet[ch] = sig;
            }

            // Stage H: mid/side widening
            if nch >= 2 {
                let mid = (wet[0] + wet[1]) * 0.5;
                let side = (wet[0] - wet[1]) * 0.5 * 1.7;
                wet[0] = mid + side;
                wet[1] = mid - side;
            }

            // Stage I: final highpass + wet/dry mix
            for ch in 0..nch {
                let dry = ctx.input(ch, f) as f64;
                let sig = HP[ch].process_sample(wet[ch]);
                ctx.set_output(ch, f, (dry * (1.0 - mx) + sig * mx) as f32);
            }
        }
    }
}
