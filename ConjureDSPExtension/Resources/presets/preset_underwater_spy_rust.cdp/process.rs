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

persist_buf!(LP: [Biquad; 2] = [Biquad::new(); 2]);
persist_buf!(CAV: [Biquad; 2] = [Biquad::new(); 2]);
persist_buf!(VIB: [DelayLine<MAX_DL>; 2] = [DelayLine::new(); 2]);
persist_buf!(CH: [[DelayLine<MAX_DL>; 4]; 2] = [[DelayLine::new(); 4]; 2]);
persist_buf!(AP: [[DelayLine<MAX_DL>; 4]; 2] = [[DelayLine::new(); 4]; 2]);
persist_buf!(APS: [[f64; 4]; 2] = [[0.0; 4]; 2]);
persist_buf!(TANK: [DelayLine<MAX_DL>; 2] = [DelayLine::new(); 2]);
persist_buf!(TANK_LP: [Biquad; 2] = [Biquad::new(); 2]);
persist_buf!(TANK_FB: [f64; 2] = [0.0; 2]);
persist_buf!(SLAP: [DelayLine<MAX_DL>; 2] = [DelayLine::new(); 2]);
persist_buf!(SLAP_LP: [Biquad; 2] = [Biquad::new(); 2]);
persist_buf!(SLAP_FB: [f64; 2] = [0.0; 2]);
persist_buf!(LFO_VIB: Lfo = Lfo::new());
persist_buf!(LFOS_CH: [Lfo; 4] = [Lfo::new(); 4]);
persist_buf!(LFO_TREM: Lfo = Lfo::new());

process! { ctx =>
    let sr = ctx.sample_rate() as f64;

    let depth_hz = ctx.param(DEPTH) as f64;
    let bubble_ms = ctx.param(BUBBLE) as f64;
    let spring = ctx.param(SPRING) as f64 / 100.0;
    let tide = ctx.param(TIDE) as f64 / 100.0;
    let mx = ctx.param(MIX) as f64;

    // Filter coefficients
    let lpc = BiquadCoeffs::lowpass(depth_hz, 2.0, sr);
    let cavc = BiquadCoeffs::peak(250.0, 3.0, 6.0, sr);
    let fblpc = BiquadCoeffs::lowpass(2500.0, 0.707, sr);

    let nch = ctx.channels().min(2);

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

    LP.with_mut(|lp| {
        CAV.with_mut(|cav| {
            VIB.with_mut(|vib| {
                CH.with_mut(|ch_buf| {
                    AP.with_mut(|ap| {
                        APS.with_mut(|aps| {
                            TANK.with_mut(|tank| {
                                TANK_LP.with_mut(|tank_lp| {
                                    TANK_FB.with_mut(|tank_fb| {
                                        SLAP.with_mut(|slap| {
                                            SLAP_LP.with_mut(|slap_lp| {
                                                SLAP_FB.with_mut(|slap_fb| {
                                                    LFO_VIB.with_mut(|lfo_vib| {
                                                        LFOS_CH.with_mut(|lfos_ch| {
                                                            LFO_TREM.with_mut(|lfo_trem| {
                                                                // LFO init
                                                                lfo_vib.init(sr, 6.0);
                                                                for l in 0..4 {
                                                                    lfos_ch[l].init(sr, LFO_CH_HZ[l]);
                                                                }
                                                                lfo_trem.init(sr, 4.0);
                                                                lfo_trem.set_waveform(Waveform::Triangle);

                                                                for ch in 0..nch {
                                                                    lp[ch].set_coeffs(lpc);
                                                                    cav[ch].set_coeffs(cavc);
                                                                    tank_lp[ch].set_coeffs(fblpc);
                                                                    slap_lp[ch].set_coeffs(fblpc);
                                                                }

                                                                let mut wet: [f64; 2] = [0.0; 2];

                                                                for f in 0..ctx.frames() {
                                                                    let v = lfo_vib.tick();
                                                                    let m0 = lfos_ch[0].tick();
                                                                    let m1 = lfos_ch[1].tick();
                                                                    let m2 = lfos_ch[2].tick();
                                                                    let m3 = lfos_ch[3].tick();
                                                                    let trem = lfo_trem.tick();
                                                                    let trem_gain = 1.0 - tide * 0.25 * (1.0 - trem);

                                                                    for ch in 0..nch {
                                                                        let dry = ctx.input(ch, f) as f64;

                                                                        // Stage A: underwater lowpass
                                                                        let mut x = lp[ch].process_sample(dry);

                                                                        // Stage B: water cavity peak
                                                                        x = cav[ch].process_sample(x);

                                                                        // Stage C: vibrato pre-stage
                                                                        vib[ch].write(x as f32);
                                                                        x = vib[ch].read((vib_d + v * vib_depth).max(1.0)) as f64;

                                                                        // Stage D: 4-voice chorus
                                                                        for c in 0..4 {
                                                                            ch_buf[ch][c].write(x as f32);
                                                                        }
                                                                        let d0 = (ch_d[0] + m0 * bubble_samp).max(1.0);
                                                                        let d1 = (ch_d[1] + m1 * bubble_samp).max(1.0);
                                                                        let d2 = (ch_d[2] + m2 * bubble_samp).max(1.0);
                                                                        let d3 = (ch_d[3] + m3 * bubble_samp).max(1.0);
                                                                        let csum = (ch_buf[ch][0].read(d0) as f64
                                                                            + ch_buf[ch][1].read(d1) as f64
                                                                            + ch_buf[ch][2].read(d2) as f64
                                                                            + ch_buf[ch][3].read(d3) as f64)
                                                                            * 0.25;

                                                                        let mut sig = csum;

                                                                        // Stage E: 4 cascaded Schroeder allpass diffusers
                                                                        for a in 0..4 {
                                                                            let vd = aps[ch][a];
                                                                            let vn = sig + AP_G * vd;
                                                                            ap[ch][a].write(vn as f32);
                                                                            aps[ch][a] = ap[ch][a].read(ap_d[a]) as f64;
                                                                            sig = vd - AP_G * vn;
                                                                        }

                                                                        // Stage F: spring tank feedback comb (LP in feedback loop)
                                                                        let tflt = tank_lp[ch].process_sample(tank_fb[ch]);
                                                                        tank[ch].write((sig + tank_fb_amt * tflt) as f32);
                                                                        tank_fb[ch] = tank[ch].read(tank_d) as f64;
                                                                        sig = sig + 0.6 * tank_fb[ch];

                                                                        // Stage G: Bond tape slap
                                                                        let sflt = slap_lp[ch].process_sample(slap_fb[ch]);
                                                                        slap[ch].write((sig + slap_fb_amt * sflt) as f32);
                                                                        slap_fb[ch] = slap[ch].read(slap_d) as f64;
                                                                        sig = sig + 0.3 * slap_fb[ch];

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
                                                            });
                                                        });
                                                    });
                                                });
                                            });
                                        });
                                    });
                                });
                            });
                        });
                    });
                });
            });
        });
    });
}
