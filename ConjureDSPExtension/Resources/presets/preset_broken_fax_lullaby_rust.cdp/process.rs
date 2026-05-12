// Broken Fax Lullaby — broken fax machine trying to sing a lullaby.
//
// Lullaby chorus pre-stage → 4-carrier ring modulation (real fax modem
// frequencies, gated by deterministic square LFO patterns) → telephony
// bandpass → sample-and-hold rate reduction → bit-depth reduction →
// mechanical comb buzz → 60 Hz mains hum → highpass cleanup → mix.
//
// Params:
//   DRIFT   (pct) — chorus depth (machine-wobble feel)
//   CRUSH   (pct) — bit reduction amount, 0=clean / 100=destroyed
//   GATE    (Hz)  — dropout rate (0.5–8)
//   LULLABY (pct) — chorus mix into wet bus
//   MIX           — wet/dry blend

use conjuredsp::*;
params! {
    DRIFT = pct().default(40.0),
    CRUSH = pct().default(55.0),
    GATE = freq().min(0.5).max(8.0).default(2.0),
    LULLABY = pct().default(60.0),
    MIX = mix().default(0.55),
}

const MAX_DL: usize = 4800;
const CARRIER_HZ: [f64; 4] = [1100.0, 1300.0, 2100.0, 2300.0];
const GATE_HZ: [f64; 4] = [0.4, 0.6, 0.7, 0.9];
const CHORUS_BASE_MS: f64 = 9.0;
const CHORUS_DEPTH_MS: f64 = 1.2;
const COMB_MS: f64 = 9.4;
const COMB_FB_AMT: f64 = 0.55;

persist_buf!(CHORUS: [DelayLine<MAX_DL>; 2] = [DelayLine::new(); 2]);
persist_buf!(COMB: [DelayLine<MAX_DL>; 2] = [DelayLine::new(); 2]);
persist_buf!(COMB_FB: [f64; 2] = [0.0; 2]);
persist_buf!(BP: [Biquad; 2] = [Biquad::new(); 2]);
persist_buf!(HP: [Biquad; 2] = [Biquad::new(); 2]);
persist_buf!(SH_HELD: [f64; 2] = [0.0; 2]);
persist!(SH_COUNT: usize = 0);
persist_buf!(LFO_CHORUS: Lfo = Lfo::new());
persist_buf!(LFO_CARRIERS: [Lfo; 4] = [Lfo::new(); 4]);
persist_buf!(LFO_GATES: [Lfo; 4] = [Lfo::new(); 4]);
persist_buf!(LFO_DROPOUT: Lfo = Lfo::new());
persist_buf!(LFO_HUM: Lfo = Lfo::new());
persist!(GATE_ENV: f64 = 1.0);

process! { ctx =>
    let sr = ctx.sample_rate() as f64;

    let drift = ctx.param(DRIFT) as f64 / 100.0;
    let crush = ctx.param(CRUSH) as f64 / 100.0;
    let gate_hz = ctx.param(GATE) as f64;
    let lullaby = ctx.param(LULLABY) as f64 / 100.0;
    let mx = ctx.param(MIX) as f64;

    // Telephony bandpass and final highpass
    let bpc = BiquadCoeffs::bandpass(1700.0, 2.0, sr);
    let hpc = BiquadCoeffs::highpass(250.0, 0.707, sr);
    let nch = ctx.channels().min(2);

    let chorus_d = CHORUS_BASE_MS * 0.001 * sr;
    let chorus_depth = CHORUS_DEPTH_MS * drift * 0.001 * sr;
    let comb_d = (COMB_MS * 0.001 * sr).max(1.0);

    // Bit-crush levels: 2 bits at crush=1, 10 bits at crush=0
    let bits = 10.0 - 8.0 * crush;
    let levels = (2.0_f64).powf(bits);
    let inv_levels = 1.0 / levels;

    // Sample-and-hold period: 2 → 12 samples
    let sh_period = ((2.0 + 10.0 * crush) as usize).max(1);

    // Smoothing for the dropout gate envelope (10 ms one-pole)
    let gate_alpha = (-1.0_f64 / (0.010 * sr)).exp();
    let one_minus_alpha = 1.0 - gate_alpha;

    let hum_gain: f64 = 0.079; // ≈ −22 dB

    let mut sh_count = SH_COUNT.get();
    let mut gate_env = GATE_ENV.get();

    CHORUS.with_mut(|chorus| {
        COMB.with_mut(|comb| {
            COMB_FB.with_mut(|comb_fb| {
                BP.with_mut(|bp| {
                    HP.with_mut(|hp| {
                        SH_HELD.with_mut(|sh_held| {
                            LFO_CHORUS.with_mut(|lfo_chorus| {
                                LFO_CARRIERS.with_mut(|lfo_carriers| {
                                    LFO_GATES.with_mut(|lfo_gates| {
                                        LFO_DROPOUT.with_mut(|lfo_dropout| {
                                            LFO_HUM.with_mut(|lfo_hum| {
                                                // LFO init
                                                lfo_chorus.init(sr, 1.5);
                                                for i in 0..4 {
                                                    lfo_carriers[i].init(sr, CARRIER_HZ[i]);
                                                    lfo_gates[i].init(sr, GATE_HZ[i]);
                                                    lfo_gates[i].set_waveform(Waveform::Square);
                                                }
                                                lfo_dropout.init(sr, gate_hz);
                                                lfo_dropout.set_waveform(Waveform::Square);
                                                lfo_hum.init(sr, 60.0);

                                                for ch in 0..nch {
                                                    bp[ch].set_coeffs(bpc);
                                                    hp[ch].set_coeffs(hpc);
                                                }

                                                for f in 0..ctx.frames() {
                                                    let c_lfo = lfo_chorus.tick();
                                                    let car0 = lfo_carriers[0].tick();
                                                    let car1 = lfo_carriers[1].tick();
                                                    let car2 = lfo_carriers[2].tick();
                                                    let car3 = lfo_carriers[3].tick();
                                                    let g0 = (lfo_gates[0].tick() + 1.0) * 0.5;
                                                    let g1 = (lfo_gates[1].tick() + 1.0) * 0.5;
                                                    let g2 = (lfo_gates[2].tick() + 1.0) * 0.5;
                                                    let g3 = (lfo_gates[3].tick() + 1.0) * 0.5;
                                                    let drop = (lfo_dropout.tick() + 1.0) * 0.5;
                                                    let hum = lfo_hum.tick();

                                                    gate_env = gate_alpha * gate_env + one_minus_alpha * drop;

                                                    let update_held = (sh_count % sh_period) == 0;
                                                    sh_count += 1;

                                                    for ch in 0..nch {
                                                        let dry = ctx.input(ch, f) as f64;

                                                        // Stage A: lullaby chorus pre-stage
                                                        chorus[ch].write(dry as f32);
                                                        let chorus_read = (chorus_d + c_lfo * chorus_depth).max(1.0);
                                                        let chr_voice = chorus[ch].read(chorus_read) as f64;
                                                        let x = dry + lullaby * (chr_voice - dry);

                                                        // Stage B: 4-carrier ring modulation, gated
                                                        let mut ring = (x * car0 * g0
                                                            + x * car1 * g1
                                                            + x * car2 * g2
                                                            + x * car3 * g3)
                                                            * 0.25;

                                                        // Stage C: telephony bandpass
                                                        ring = bp[ch].process_sample(ring);

                                                        // Stage D: sample-and-hold (rate reduction)
                                                        if update_held {
                                                            sh_held[ch] = ring;
                                                        }
                                                        let mut sig = sh_held[ch];

                                                        // Stage E: bit-depth reduction
                                                        sig = (sig * levels + 0.5).floor() * inv_levels;

                                                        // Stage F: smoothed dropout gate
                                                        sig = sig * gate_env;

                                                        // Stage G: mechanical comb buzz
                                                        comb[ch].write((sig + COMB_FB_AMT * comb_fb[ch]) as f32);
                                                        comb_fb[ch] = comb[ch].read(comb_d) as f64;
                                                        sig = sig + 0.4 * comb_fb[ch];

                                                        // Stage H: 60 Hz mains hum
                                                        sig = sig + hum * hum_gain;

                                                        // Stage I: final highpass
                                                        sig = hp[ch].process_sample(sig);

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
    });

    SH_COUNT.set(sh_count);
    GATE_ENV.set(gate_env);
}
