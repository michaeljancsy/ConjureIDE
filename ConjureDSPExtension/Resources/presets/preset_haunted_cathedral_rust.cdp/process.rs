
use conjuredsp::*;
setup!();

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

static mut PD: [DelayLine<MAX_DL>; 2] = [DelayLine::new(); 2];
static mut CB: [[DelayLine<MAX_DL>; 4]; 2] = [[DelayLine::new(); 4]; 2];
static mut CLP: [[Biquad; 4]; 2] = [[Biquad::new(); 4]; 2];
static mut CFB: [[f64; 4]; 2] = [[0.0; 4]; 2];
static mut AP: [[DelayLine<MAX_DL>; 2]; 2] = [[DelayLine::new(); 2]; 2];
static mut APS: [[f64; 2]; 2] = [[0.0; 2]; 2];
static mut HP: [Biquad; 2] = [Biquad::new(); 2];
static mut LFOS: [Lfo; 4] = [Lfo::new(); 4];

#[no_mangle]
pub extern "C" fn process(
    input: *const f32, output: *mut f32,
    channels: i32, frame_count: i32, sample_rate: f32,
) {
    let ctx = ctx(input, output, channels, frame_count, sample_rate);
    let sr = ctx.sample_rate() as f64;

    unsafe {
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

        for l in 0..4 {
            LFOS[l].init(sr, LFO_HZ[l]);
        }

        let nch = ctx.channels().min(2);
        for ch in 0..nch {
            for c in 0..4 {
                CLP[ch][c].set_coeffs(lpc);
            }
            HP[ch].set_coeffs(hpc);
        }

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

        for f in 0..ctx.frames() {
            let m = [
                LFOS[0].tick(),
                LFOS[1].tick(),
                LFOS[2].tick(),
                LFOS[3].tick(),
            ];

            for ch in 0..nch {
                let dry = ctx.input(ch, f) as f64;

                PD[ch].write(dry as f32);
                let x = PD[ch].read(pd_samp) as f64;

                let mut csum: f64 = 0.0;
                for c in 0..4 {
                    let d = (cb_d[c] + m[c] * mod_depth).max(1.0);
                    let flt = CLP[ch][c].process_sample(CFB[ch][c]);
                    CB[ch][c].write((x + fb * flt) as f32);
                    CFB[ch][c] = CB[ch][c].read_cubic(d) as f64;
                    csum += CFB[ch][c];
                }

                let mut sig = csum * 0.25;

                for a in 0..2 {
                    let vd = APS[ch][a];
                    let vn = sig + AP_G * vd;
                    AP[ch][a].write(vn as f32);
                    APS[ch][a] = AP[ch][a].read(ap_d[a]) as f64;
                    sig = vd - AP_G * vn;
                }

                sig = HP[ch].process_sample(sig);

                ctx.set_output(ch, f, (dry * (1.0 - mx) + sig * mx) as f32);
            }
        }
    }
}
