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

persist_buf!(BP: [Biquad; 2] = [Biquad::new(); 2]);
persist_buf!(SQUEAL: [DelayLine<MAX_DL>; 2] = [DelayLine::new(); 2]);
persist_buf!(SQUEAL_FB: [f64; 2] = [0.0; 2]);
persist_buf!(HP: [Biquad; 2] = [Biquad::new(); 2]);
persist_buf!(SH_HELD: [f64; 2] = [0.0; 2]);
persist!(SH_COUNT: usize = 0);
persist_buf!(LFO_DRIFT: Lfo = Lfo::new());
persist_buf!(LFO_CARRIERS: [Lfo; 2] = [Lfo::new(); 2]);
persist_buf!(LFO_TREM: Lfo = Lfo::new());
persist!(TREM_ENV: f64 = 1.0);
persist_buf!(LFO_INTERFERE_AMP: Lfo = Lfo::new());
persist_buf!(LFO_INTERFERE_TONE: Lfo = Lfo::new());

process! { ctx =>
    let sr = ctx.sample_rate() as f64;

    let drift = ctx.param(DRIFT) as f64 / 100.0;
    let interference = ctx.param(INTERFERENCE) as f64 / 100.0;
    let static_amt = ctx.param(STATIC) as f64 / 100.0;
    let crush = ctx.param(CRUSH) as f64 / 100.0;
    let mx = ctx.param(MIX) as f64;

    let nch = ctx.channels().min(2);

    // Final highpass at 250 Hz (per-channel state, same coeffs)
    let hpc = BiquadCoeffs::highpass(250.0, 0.707, sr);

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

    let mut sh_count = SH_COUNT.get();
    let mut trem_env = TREM_ENV.get();

    BP.with_mut(|bp| {
        SQUEAL.with_mut(|squeal| {
            SQUEAL_FB.with_mut(|squeal_fb| {
                HP.with_mut(|hp| {
                    SH_HELD.with_mut(|sh_held| {
                        LFO_DRIFT.with_mut(|lfo_drift| {
                            LFO_CARRIERS.with_mut(|lfo_carriers| {
                                LFO_TREM.with_mut(|lfo_trem| {
                                    LFO_INTERFERE_AMP.with_mut(|lfo_interfere_amp| {
                                        LFO_INTERFERE_TONE.with_mut(|lfo_interfere_tone| {
                                            // LFO init
                                            lfo_drift.init(sr, DRIFT_LFO_HZ);
                                            lfo_carriers[0].init(sr, CARRIER_HZ[0]);
                                            lfo_carriers[1].init(sr, CARRIER_HZ[1]);
                                            lfo_trem.init(sr, TREM_HZ);
                                            lfo_trem.set_waveform(Waveform::Square);
                                            lfo_interfere_amp.init(sr, INTERFERE_LFO_HZ);
                                            lfo_interfere_tone.init(sr, INTERFERE_TONE_HZ);

                                            // Per-channel bandpass coefficients
                                            for ch in 0..nch {
                                                let bpc = BiquadCoeffs::bandpass(BP_HZ[ch], BP_Q, sr);
                                                bp[ch].set_coeffs(bpc);
                                            }

                                            for ch in 0..nch {
                                                hp[ch].set_coeffs(hpc);
                                            }

                                            let mut wet: [f64; 2] = [0.0; 2];

                                            for f in 0..ctx.frames() {
                                                let d_lfo = lfo_drift.tick();
                                                let car0 = lfo_carriers[0].tick();
                                                let car1 = lfo_carriers[1].tick();
                                                let trem = (lfo_trem.tick() + 1.0) * 0.5;
                                                let ia = lfo_interfere_amp.tick();
                                                let it = lfo_interfere_tone.tick();

                                                trem_env = trem_alpha * trem_env + one_minus_alpha * trem;
                                                let trem_gain = 1.0 - trem_depth * (1.0 - trem_env);

                                                let update_held = (sh_count % sh_period) == 0;
                                                sh_count += 1;

                                                let interfere = it * (0.5 + 0.5 * ia) * interfere_gain;

                                                let car_mod0 = car0 * (1.0 + drift * 0.3 * d_lfo);
                                                let car_mod1 = car1 * (1.0 + drift * 0.3 * d_lfo);
                                                let car = [car_mod0, car_mod1];

                                                for ch in 0..nch {
                                                    let dry = ctx.input(ch, f) as f64;

                                                    // Stage A: per-channel bandpass
                                                    let mut x = bp[ch].process_sample(dry);

                                                    // Stage B: per-channel ring modulation
                                                    x = x * car[ch];

                                                    // Stage C: heterodyne squeal feedback comb
                                                    squeal[ch].write((x + squeal_fb_amt * squeal_fb[ch]) as f32);
                                                    squeal_fb[ch] = squeal[ch].read(squeal_d[ch]) as f64;
                                                    x = x + 0.5 * squeal_fb[ch];

                                                    // Stage D: sample-and-hold rate reduction
                                                    if update_held {
                                                        sh_held[ch] = x;
                                                    }
                                                    let mut sig = sh_held[ch];

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
                                                    let sig = hp[ch].process_sample(wet[ch]);
                                                    ctx.set_output(ch, f, (dry * (1.0 - mx) + sig * mx) as f32);
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

    SH_COUNT.set(sh_count);
    TREM_ENV.set(trem_env);
}
