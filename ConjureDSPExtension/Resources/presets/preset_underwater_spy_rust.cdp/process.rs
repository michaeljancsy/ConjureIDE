// Underwater Spy — guitar played underwater in a 1960s spy movie.
//
// Resonant underwater lowpass + 250 Hz cavity resonance → vibrato pre-stage →
// 4-voice chorus → spring-reverb impression (4 cascaded Schroeder allpasses +
// feedback tank) → Bond-era tape slap → tremolo → mid/side widening → mix.
//
// Params:
//   DEPTH  (Hz)  — underwater LP cutoff (300–2000, log)
//   BUBBLE (ms)  — chorus depth (0.5–8)
//   SPRING (pct) — spring tank feedback amount (0–100)
//   TIDE   (pct) — tremolo depth (0–100)
//   MIX          — wet/dry blend

use conjuredsp::*;
params! {
    DEPTH = freq().min(300.0).max(2000.0).default(900.0),
    BUBBLE = time_ms().min(0.5).max(8.0).default(3.0),
    SPRING = pct().default(55.0),
    TIDE = pct().default(35.0),
    MIX = mix().default(0.55),
}

const MAX_DL: usize = 24000;

const CH_MS: [f64; 4] = [4.0, 7.0, 11.0, 15.0];
const AP_MS: [f64; 4] = [5.1, 7.3, 11.7, 17.3];
const AP_G: f64 = 0.55;
const TANK_MS: f64 = 38.0;
const SLAP_MS: f64 = 95.0;
const VIB_MS: f64 = 5.0;
const VIB_DEPTH_MS: f64 = 0.25;
const LFO_CH_HZ: [f64; 4] = [0.4, 0.5, 0.6, 0.8];

static mut LP: [Biquad; 2] = [Biquad::new(); 2];
static mut CAV: [Biquad; 2] = [Biquad::new(); 2];
static mut VIB: [DelayLine<MAX_DL>; 2] = [DelayLine::new(); 2];
static mut CH: [[DelayLine<MAX_DL>; 4]; 2] = [[DelayLine::new(); 4]; 2];
static mut AP: [[DelayLine<MAX_DL>; 4]; 2] = [[DelayLine::new(); 4]; 2];
static mut APS: [[f64; 4]; 2] = [[0.0; 4]; 2];
static mut TANK: [DelayLine<MAX_DL>; 2] = [DelayLine::new(); 2];
static mut TANK_LP: [Biquad; 2] = [Biquad::new(); 2];
static mut TANK_FB: [f64; 2] = [0.0; 2];
static mut SLAP: [DelayLine<MAX_DL>; 2] = [DelayLine::new(); 2];
static mut SLAP_LP: [Biquad; 2] = [Biquad::new(); 2];
static mut SLAP_FB: [f64; 2] = [0.0; 2];
static mut LFO_VIB: Lfo = Lfo::new();
static mut LFOS_CH: [Lfo; 4] = [Lfo::new(); 4];
static mut LFO_TREM: Lfo = Lfo::new();

process! { ctx =>
    let sr = ctx.sample_rate() as f64;

    unsafe {
        let depth_hz = ctx.param(DEPTH) as f64;
        let bubble_ms = ctx.param(BUBBLE) as f64;
        let spring = ctx.param(SPRING) as f64 / 100.0;
        let tide = ctx.param(TIDE) as f64 / 100.0;
        let mx = ctx.param(MIX) as f64;

        // Filter coefficients
        let lpc = BiquadCoeffs::lowpass(depth_hz, 2.0, sr);
        let cavc = BiquadCoeffs::peak(250.0, 3.0, 6.0, sr);
        let fblpc = BiquadCoeffs::lowpass(2500.0, 0.707, sr);

        // LFO init
        LFO_VIB.init(sr, 6.0);
        for l in 0..4 {
            LFOS_CH[l].init(sr, LFO_CH_HZ[l]);
        }
        LFO_TREM.init(sr, 4.0);
        LFO_TREM.set_waveform(Waveform::Triangle);

        let nch = ctx.channels().min(2);
        for ch in 0..nch {
            LP[ch].set_coeffs(lpc);
            CAV[ch].set_coeffs(cavc);
            TANK_LP[ch].set_coeffs(fblpc);
            SLAP_LP[ch].set_coeffs(fblpc);
        }

        // Precomputed delay times (samples)
        let vib_d = VIB_MS * 0.001 * sr;
        let vib_depth = VIB_DEPTH_MS * 0.001 * sr;
        let ch_d = [
            CH_MS[0] * 0.001 * sr,
            CH_MS[1] * 0.001 * sr,
            CH_MS[2] * 0.001 * sr,
            CH_MS[3] * 0.001 * sr,
        ];
        let ap_d = [
            (AP_MS[0] * 0.001 * sr).max(1.0),
            (AP_MS[1] * 0.001 * sr).max(1.0),
            (AP_MS[2] * 0.001 * sr).max(1.0),
            (AP_MS[3] * 0.001 * sr).max(1.0),
        ];
        let tank_d = TANK_MS * 0.001 * sr;
        let slap_d = SLAP_MS * 0.001 * sr;

        let bubble_samp = bubble_ms * 0.001 * sr;
        let tank_fb_amt = 0.85 * spring;
        let slap_fb_amt: f64 = 0.4;

        let mut wet: [f64; 2] = [0.0; 2];

        for f in 0..ctx.frames() {
            let v = LFO_VIB.tick();
            let m0 = LFOS_CH[0].tick();
            let m1 = LFOS_CH[1].tick();
            let m2 = LFOS_CH[2].tick();
            let m3 = LFOS_CH[3].tick();
            let trem = LFO_TREM.tick();
            let trem_gain = 1.0 - tide * 0.25 * (1.0 - trem);

            for ch in 0..nch {
                let dry = ctx.input(ch, f) as f64;

                // Stage A: underwater lowpass
                let mut x = LP[ch].process_sample(dry);

                // Stage B: water cavity peak
                x = CAV[ch].process_sample(x);

                // Stage C: vibrato pre-stage
                VIB[ch].write(x as f32);
                x = VIB[ch].read((vib_d + v * vib_depth).max(1.0)) as f64;

                // Stage D: 4-voice chorus
                for c in 0..4 {
                    CH[ch][c].write(x as f32);
                }
                let d0 = (ch_d[0] + m0 * bubble_samp).max(1.0);
                let d1 = (ch_d[1] + m1 * bubble_samp).max(1.0);
                let d2 = (ch_d[2] + m2 * bubble_samp).max(1.0);
                let d3 = (ch_d[3] + m3 * bubble_samp).max(1.0);
                let csum = (CH[ch][0].read(d0) as f64
                    + CH[ch][1].read(d1) as f64
                    + CH[ch][2].read(d2) as f64
                    + CH[ch][3].read(d3) as f64)
                    * 0.25;

                let mut sig = csum;

                // Stage E: 4 cascaded Schroeder allpass diffusers
                for a in 0..4 {
                    let vd = APS[ch][a];
                    let vn = sig + AP_G * vd;
                    AP[ch][a].write(vn as f32);
                    APS[ch][a] = AP[ch][a].read(ap_d[a]) as f64;
                    sig = vd - AP_G * vn;
                }

                // Stage F: spring tank feedback comb (LP in feedback loop)
                let tflt = TANK_LP[ch].process_sample(TANK_FB[ch]);
                TANK[ch].write((sig + tank_fb_amt * tflt) as f32);
                TANK_FB[ch] = TANK[ch].read(tank_d) as f64;
                sig = sig + 0.6 * TANK_FB[ch];

                // Stage G: Bond tape slap
                let sflt = SLAP_LP[ch].process_sample(SLAP_FB[ch]);
                SLAP[ch].write((sig + slap_fb_amt * sflt) as f32);
                SLAP_FB[ch] = SLAP[ch].read(slap_d) as f64;
                sig = sig + 0.3 * SLAP_FB[ch];

                // Stage H: tremolo gain
                sig = sig * trem_gain;

                wet[ch] = sig;
            }

            // Stage I: mid/side widening
            if nch >= 2 {
                let mid = (wet[0] + wet[1]) * 0.5;
                let side = (wet[0] - wet[1]) * 0.5 * 1.5;
                wet[0] = mid + side;
                wet[1] = mid - side;
            }

            // Stage J: final wet/dry mix
            for ch in 0..nch {
                let dry = ctx.input(ch, f) as f64;
                ctx.set_output(ch, f, (dry * (1.0 - mx) + wet[ch] * mx) as f32);
            }
        }
    }
}
