// Broken Fax Lullaby — broken fax machine trying to sing a lullaby.
//
// Lullaby chorus pre-stage → 4-carrier ring modulation (real fax modem
// frequencies, gated by deterministic square LFO patterns) → telephony
// bandpass → sample-and-hold rate reduction → bit-depth reduction →
// mechanical comb buzz → 60 Hz mains hum → highpass cleanup → mix.
//
// Controls:
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

// Lullaby chorus pre-stage: machine-wobble delay line + modulation LFO.
struct Chorus {
    dl: [DelayLine<MAX_DL>; 2],
    lfo: Lfo,
}

// 4-carrier ring modulation: carrier sines + square-wave gate envelopes.
struct Carriers {
    lfo_car: [Lfo; 4],
    lfo_gates: [Lfo; 4],
}

// Telephony bandpass at the head of the post-ringmod chain + final
// highpass cleanup. Bundled because they share the per-channel
// `set_coeffs` loop and bookend the destructive middle.
struct Filters {
    bp: [Biquad; 2],
    hp: [Biquad; 2],
}

// Destructive middle: sample-and-hold held value + mechanical comb buzz
// (delay + feedback). Named `Crusher` (not `Crush`) so the static doesn't
// clash with the `CRUSH` parameter index const.
struct Crusher {
    sh_held: [f64; 2],
    comb_dl: [DelayLine<MAX_DL>; 2],
    comb_fb: [f64; 2],
}

// Atmospheric noise generators: dropout-gate square LFO + 60 Hz mains hum.
struct Atmos {
    lfo_dropout: Lfo,
    lfo_hum: Lfo,
}

persist_mut!(CHORUS: Chorus = Chorus {
    dl: [const { DelayLine::new() }; 2],
    lfo: Lfo::new(),
});
persist_mut!(CARRIERS: Carriers = Carriers {
    lfo_car: [const { Lfo::new() }; 4],
    lfo_gates: [const { Lfo::new() }; 4],
});
persist_mut!(FILTERS: Filters = Filters {
    bp: [const { Biquad::new() }; 2],
    hp: [const { Biquad::new() }; 2],
});
persist_mut!(CRUSHER: Crusher = Crusher {
    sh_held: [0.0; 2],
    comb_dl: [const { DelayLine::new() }; 2],
    comb_fb: [0.0; 2],
});
persist_mut!(ATMOS: Atmos = Atmos {
    lfo_dropout: Lfo::new(),
    lfo_hum: Lfo::new(),
});

persist!(SH_COUNT: usize = 0);
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
        CARRIERS.with_mut(|carriers| {
            FILTERS.with_mut(|filters| {
                CRUSHER.with_mut(|crusher| {
                    ATMOS.with_mut(|atmos| {
                        // LFO init
                        chorus.lfo.init(sr, 1.5);
                        for i in 0..4 {
                            carriers.lfo_car[i].init(sr, CARRIER_HZ[i]);
                            carriers.lfo_gates[i].init(sr, GATE_HZ[i]);
                            carriers.lfo_gates[i].set_waveform(Waveform::Square);
                        }
                        atmos.lfo_dropout.init(sr, gate_hz);
                        atmos.lfo_dropout.set_waveform(Waveform::Square);
                        atmos.lfo_hum.init(sr, 60.0);

                        for ch in 0..nch {
                            filters.bp[ch].set_coeffs(bpc);
                            filters.hp[ch].set_coeffs(hpc);
                        }

                        for f in 0..ctx.frames() {
                            let c_lfo = chorus.lfo.tick();
                            let car0 = carriers.lfo_car[0].tick();
                            let car1 = carriers.lfo_car[1].tick();
                            let car2 = carriers.lfo_car[2].tick();
                            let car3 = carriers.lfo_car[3].tick();
                            let g0 = (carriers.lfo_gates[0].tick() + 1.0) * 0.5;
                            let g1 = (carriers.lfo_gates[1].tick() + 1.0) * 0.5;
                            let g2 = (carriers.lfo_gates[2].tick() + 1.0) * 0.5;
                            let g3 = (carriers.lfo_gates[3].tick() + 1.0) * 0.5;
                            let drop = (atmos.lfo_dropout.tick() + 1.0) * 0.5;
                            let hum = atmos.lfo_hum.tick();

                            gate_env = gate_alpha * gate_env + one_minus_alpha * drop;

                            let update_held = (sh_count % sh_period) == 0;
                            sh_count += 1;

                            for ch in 0..nch {
                                let dry = ctx.input(ch, f) as f64;

                                // Stage A: lullaby chorus pre-stage
                                chorus.dl[ch].write(dry as f32);
                                let chorus_read = (chorus_d + c_lfo * chorus_depth).max(1.0);
                                let chr_voice = chorus.dl[ch].read(chorus_read) as f64;
                                let x = dry + lullaby * (chr_voice - dry);

                                // Stage B: 4-carrier ring modulation, gated
                                let mut ring = (x * car0 * g0
                                    + x * car1 * g1
                                    + x * car2 * g2
                                    + x * car3 * g3)
                                    * 0.25;

                                // Stage C: telephony bandpass
                                ring = filters.bp[ch].process_sample(ring);

                                // Stage D: sample-and-hold (rate reduction)
                                if update_held {
                                    crusher.sh_held[ch] = ring;
                                }
                                let mut sig = crusher.sh_held[ch];

                                // Stage E: bit-depth reduction
                                sig = (sig * levels + 0.5).floor() * inv_levels;

                                // Stage F: smoothed dropout gate
                                sig = sig * gate_env;

                                // Stage G: mechanical comb buzz
                                crusher.comb_dl[ch].write((sig + COMB_FB_AMT * crusher.comb_fb[ch]) as f32);
                                crusher.comb_fb[ch] = crusher.comb_dl[ch].read(comb_d) as f64;
                                sig = sig + 0.4 * crusher.comb_fb[ch];

                                // Stage H: 60 Hz mains hum
                                sig = sig + hum * hum_gain;

                                // Stage I: final highpass
                                sig = filters.hp[ch].process_sample(sig);

                                ctx.set_output(ch, f, (dry * (1.0 - mx) + sig * mx) as f32);
                            }
                        }
                    });
                });
            });
        });
    });

    SH_COUNT.set(sh_count);
    GATE_ENV.set(gate_env);
}
