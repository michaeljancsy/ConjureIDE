// Tremolo — sine-based amplitude modulation.
//
// Modulates the audio amplitude with a low-frequency sine oscillator (LFO).
// The LFO phase is tracked across callbacks for seamless modulation.
//
// Params:
//   0 (Rate):  LFO rate — 0.5 to 20 Hz
//   1 (Depth): Tremolo depth — 0.0 to 1.0

const MAX_CH: usize = 2;
const MAX_FR: usize = 4096;

static mut INPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut OUTPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut PARAMS_BUF: [f32; 16] = [0.0; 16];

// Parameter indices
const RATE: usize = 0;  // 0.5–20 Hz
const DEPTH: usize = 1; // 0.0–1.0

// Persistent phase across callbacks
// Use f64 to match Python's float64 precision in the phase accumulator.
static mut PHASE: f64 = 0.0;

static METADATA: &str = r#"[{"name":"Rate","min":0.5,"max":20.0,"unit":"Hz","default":5.0},{"name":"Depth","min":0.0,"max":1.0,"unit":"","default":0.5}]"#;

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

/// Tremolo — sine-based amplitude modulation.
///
/// Computes a per-sample LFO gain using a sine wave, then multiplies
/// each input sample by that gain. The phase accumulates across callbacks so the
/// modulation is seamless between audio buffers. All channels share the same LFO.
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
        let depth = PARAMS_BUF[DEPTH] as f64;

        let phase_inc = two_pi * rate_hz / sr;
        let inp = std::slice::from_raw_parts(input, ch * frames);
        let out = std::slice::from_raw_parts_mut(output, ch * frames);
        let mut phase = PHASE;

        for i in 0..frames {
            let lfo = 1.0 - depth * 0.5 * (1.0 + phase.sin());
            for c in 0..ch {
                let idx = c * frames + i;
                out[idx] = (inp[idx] as f64 * lfo) as f32;
            }
            phase += phase_inc;
        }

        PHASE = phase % two_pi;
    }
}
