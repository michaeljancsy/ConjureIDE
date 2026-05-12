
use conjuredsp::*;
params! {
    DECAY = pct().default(85.0),
    DARKNESS = freq().min(200.0).max(16000.0).default(1800.0),
    HAUNT = pct().default(60.0),
    SIZE = pct().default(80.0),
    PRE_DELAY = time_ms().min(1.0).max(150.0).default(40.0),
    MIX = mix().default(0.5),
}

const MAX_DL: usize = 24000;
const COMB_MS: [f64; 4] = [59.3, 67.7, 73.1, 79.9];
const AP_MS: [f64; 2] = [12.1, 4.3];
const AP_G: f64 = 0.6;
const LFO_HZ: [f64; 4] = [0.11, 0.15, 0.19, 0.27];

persist_buf!(PD: [DelayLine<MAX_DL>; 2] = [DelayLine::new(); 2]);
persist_buf!(CB: [[DelayLine<MAX_DL>; 4]; 2] = [[DelayLine::new(); 4]; 2]);
persist_buf!(CLP: [[Biquad; 4]; 2] = [[Biquad::new(); 4]; 2]);
persist_buf!(CFB: [[f64; 4]; 2] = [[0.0; 4]; 2]);
persist_buf!(AP: [[DelayLine<MAX_DL>; 2]; 2] = [[DelayLine::new(); 2]; 2]);
persist_buf!(APS: [[f64; 2]; 2] = [[0.0; 2]; 2]);
persist_buf!(HP: [Biquad; 2] = [Biquad::new(); 2]);
persist_buf!(LFOS: [Lfo; 4] = [Lfo::new(); 4]);

process! { ctx =>
    let sr = ctx.sample_rate() as f64;

    let decay = ctx.param(DECAY) as f64 / 100.0;
    let dark = ctx.param(DARKNESS) as f64;
    let haunt = ctx.param(HAUNT) as f64 / 100.0;
    let sz = 0.5 + ctx.param(SIZE) as f64 / 100.0;
    let pd_samp = ctx.param(PRE_DELAY) as f64 * 0.001 * sr;
    let mx = ctx.param(MIX) as f64;

    let fb = 0.75 + decay * 0.22;
    let lpc = BiquadCoeffs::lowpass(dark, 0.6, sr);
    let hpc = BiquadCoeffs::highpass(80.0, 0.707, sr);
    let mod_depth = haunt * 20.0;

    let nch = ctx.channels().min(2);

    let cb_d = [
        COMB_MS[0] * sz * 0.001 * sr,
        COMB_MS[1] * sz * 0.001 * sr,
        COMB_MS[2] * sz * 0.001 * sr,
        COMB_MS[3] * sz * 0.001 * sr,
    ];
    let ap_d = [
        (AP_MS[0] * sz * 0.001 * sr).max(1.0),
        (AP_MS[1] * sz * 0.001 * sr).max(1.0),
    ];

    PD.with_mut(|pd| {
        CB.with_mut(|cb| {
            CLP.with_mut(|clp| {
                CFB.with_mut(|cfb| {
                    AP.with_mut(|ap| {
                        APS.with_mut(|aps| {
                            HP.with_mut(|hp| {
                                LFOS.with_mut(|lfos| {
                                    for l in 0..4 {
                                        lfos[l].init(sr, LFO_HZ[l]);
                                    }

                                    for ch in 0..nch {
                                        for c in 0..4 {
                                            clp[ch][c].set_coeffs(lpc);
                                        }
                                        hp[ch].set_coeffs(hpc);
                                    }

                                    for f in 0..ctx.frames() {
                                        let m = [
                                            lfos[0].tick(),
                                            lfos[1].tick(),
                                            lfos[2].tick(),
                                            lfos[3].tick(),
                                        ];

                                        for ch in 0..nch {
                                            let dry = ctx.input(ch, f) as f64;

                                            pd[ch].write(dry as f32);
                                            let x = pd[ch].read(pd_samp) as f64;

                                            let mut csum: f64 = 0.0;
                                            for c in 0..4 {
                                                let d = (cb_d[c] + m[c] * mod_depth).max(1.0);
                                                let flt = clp[ch][c].process_sample(cfb[ch][c]);
                                                cb[ch][c].write((x + fb * flt) as f32);
                                                cfb[ch][c] = cb[ch][c].read_cubic(d) as f64;
                                                csum += cfb[ch][c];
                                            }

                                            let mut sig = csum * 0.25;

                                            for a in 0..2 {
                                                let vd = aps[ch][a];
                                                let vn = sig + AP_G * vd;
                                                ap[ch][a].write(vn as f32);
                                                aps[ch][a] = ap[ch][a].read(ap_d[a]) as f64;
                                                sig = vd - AP_G * vn;
                                            }

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
}
