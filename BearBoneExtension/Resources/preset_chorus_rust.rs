// Chorus — modulated delay for thickening.
//
// Uses a short delay line with an LFO-modulated read position to create
// a detuned copy of the signal. The modulated copy is mixed with the dry
// signal, producing a rich, thickened sound. Linear interpolation is used
// for sub-sample delay accuracy.
//
// Params:
//   0 (Rate):  LFO rate — 0.1 to 2.0 Hz
//   1 (Depth): Modulation depth — 0.5 to 15.0 ms
//   2 (Delay): Base delay — 2.0 to 30.0 ms
//   3 (Mix):   Dry/wet mix — 0.0 to 1.0

const MAX_CH: usize = 2;
const MAX_FR: usize = 4096;
const MAX_DELAY: usize = 2048;

static mut INPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut OUTPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut PARAMS_BUF: [f32; 16] = [0.0; 16];

// Parameter indices
const RATE: usize = 0;  // 0.1–2.0 Hz
const DEPTH: usize = 1; // 0.5–15.0 ms
const DELAY: usize = 2; // 2.0–30.0 ms
const MIX: usize = 3;   // 0.0–1.0

// Persistent state
static mut DELAY_BUF: [[f32; MAX_DELAY]; MAX_CH] = [[0.0; MAX_DELAY]; MAX_CH];
static mut WRITE_POS: usize = 0;
// Use f64 to match Python's float64 precision in the phase accumulator.
static mut LFO_PHASE: f64 = 0.0;

static METADATA: &str = r#"[{"name":"Rate","min":0.1,"max":2.0,"unit":"Hz","default":0.5},{"name":"Depth","min":0.5,"max":15.0,"unit":"ms","default":5.0},{"name":"Delay","min":2.0,"max":30.0,"unit":"ms","default":10.0},{"name":"Mix","min":0.0,"max":1.0,"unit":"","default":0.5}]"#;

#[no_mangle]
pub extern "C" fn get_input_ptr() -> i32 {
    unsafe { INPUT_BUF.as_ptr() as i32 }
}

#[no_mangle]
pub extern "C" fn get_output_ptr() -> i32 {
    unsafe { OUTPUT_BUF.as_ptr() as i32 }
}

#[no_mangle]
pub extern "C" fn get_params_ptr() -> i32 {
    unsafe { PARAMS_BUF.as_ptr() as i32 }
}

#[no_mangle]
pub extern "C" fn get_param_metadata_ptr() -> i32 {
    METADATA.as_ptr() as i32
}

#[no_mangle]
pub extern "C" fn get_param_metadata_len() -> i32 {
    METADATA.len() as i32
}

#[no_mangle]
pub extern "C" fn process(
    input: *const f32,
    output: *mut f32,
    channels: i32,
    frame_count: i32,
    sample_rate: f32,
) {
    let ch = channels as usize;
    let frames = frame_count as usize;
    let sr = sample_rate as f64;
    let two_pi = 2.0 * core::f64::consts::PI;

    unsafe {
        let rate_hz = PARAMS_BUF[RATE] as f64;
        let depth_ms = PARAMS_BUF[DEPTH] as f64;
        let base_delay_ms = PARAMS_BUF[DELAY] as f64;
        let mix = PARAMS_BUF[MIX] as f64;

        let lfo_inc = two_pi * rate_hz / sr;
        let inp = std::slice::from_raw_parts(input, ch * frames);
        let out = std::slice::from_raw_parts_mut(output, ch * frames);
        let mut phase = LFO_PHASE;
        let mut wp = WRITE_POS;

        for i in 0..frames {
            // LFO modulates delay time
            let delay_samples = (base_delay_ms + depth_ms * phase.sin()) * sr / 1000.0;

            for c in 0..ch {
                let idx = c * frames + i;

                // Write input to delay line
                DELAY_BUF[c][wp] = inp[idx];

                // Read with linear interpolation (f64 to match Python)
                let mut read_pos = wp as f64 - delay_samples;
                if read_pos < 0.0 {
                    read_pos += MAX_DELAY as f64;
                }
                let idx0 = (read_pos as usize) % MAX_DELAY;
                let idx1 = (idx0 + 1) % MAX_DELAY;
                let frac = read_pos - read_pos.floor();
                let delayed = DELAY_BUF[c][idx0] as f64 * (1.0 - frac)
                    + DELAY_BUF[c][idx1] as f64 * frac;

                // Mix dry + wet
                out[idx] = (inp[idx] as f64 * (1.0 - mix) + delayed * mix) as f32;
            }

            phase += lfo_inc;
            wp = (wp + 1) % MAX_DELAY;
        }

        LFO_PHASE = phase % two_pi;
        WRITE_POS = wp;
    }
}
