// Resonant State Variable Filter — multi-mode TPT SVF (LP/HP/BP/Notch).
//
// Topology-preserving transform SVF (Zavalishin). Unconditionally stable
// across the full 20–20000 Hz range at any Q. The filter computes
// low-pass, high-pass, and band-pass simultaneously.
// Change MODE constant to select output: 0=LP, 1=HP, 2=BP, 3=Notch.
//
// Params:
//   0 (Cutoff):    Filter cutoff — 20 to 20000 Hz (log)
//   1 (Resonance): Resonance Q — 0.5 to 10.0

use conjuredsp::*;
setup!();

params! {
    CUTOFF = freq(),
    RESONANCE = param(0.5, 10.0).default(1.0),
}

const MODE: usize = 0; // 0=LP, 1=HP, 2=BP, 3=Notch

// Persistent state per channel: [ic1eq, ic2eq]
// Use f64 to match Python's float64 precision.
static mut IC1EQ: [f64; MAX_CH] = [0.0; MAX_CH];
static mut IC2EQ: [f64; MAX_CH] = [0.0; MAX_CH];

#[no_mangle]
pub extern "C" fn process(
    input: *const f32,
    output: *mut f32,
    channels: i32,
    frame_count: i32,
    sample_rate: f32,
) {
    let ctx = ctx(input, output, channels, frame_count, sample_rate);
    let sr = ctx.sample_rate() as f64;

    unsafe {
        let cutoff_hz = (ctx.param(CUTOFF) as f64).min(sr * 0.49);
        let resonance = ctx.param(RESONANCE) as f64;

        let g = (core::f64::consts::PI * cutoff_hz / sr).tan();
        let k = 1.0 / resonance;
        let a1 = 1.0 / (1.0 + g * (g + k));
        let a2 = g * a1;
        let a3 = g * a2;

        for c in 0..ctx.channels() {
            let mut ic1eq = IC1EQ[c];
            let mut ic2eq = IC2EQ[c];

            for i in 0..ctx.frames() {
                let x = ctx.input(c, i) as f64;
                let v3 = x - ic2eq;
                let v1 = a1 * ic1eq + a2 * v3;
                let v2 = ic2eq + a2 * ic1eq + a3 * v3;
                ic1eq = 2.0 * v1 - ic1eq;
                ic2eq = 2.0 * v2 - ic2eq;

                let low = v2;
                let band = v1;
                let high = x - k * v1 - v2;

                ctx.set_output(c, i, match MODE {
                    0 => low as f32,
                    1 => high as f32,
                    2 => band as f32,
                    _ => (low + high) as f32, // notch
                });
            }

            IC1EQ[c] = ic1eq;
            IC2EQ[c] = ic2eq;
        }
    }
}
