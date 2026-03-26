// Tremolo — sine-based amplitude modulation.
//
// Modulates the audio amplitude with a low-frequency sine oscillator (LFO).
// Supports free-running Hz rate or BPM-synced note divisions.
//
// Params:
//   0 (Sync):     0 = free Hz, 1 = BPM sync
//   1 (Rate):     LFO rate in free mode — 0.5 to 20 Hz
//   2 (Division): Note division in BPM mode — 0=1/1, 1=1/2, 2=1/4, 3=1/8, 4=1/16, 5=1/4T, 6=1/8T
//   3 (Depth):    Tremolo depth — 0.0 to 1.0

const MAX_CH: usize = 2;
const MAX_FR: usize = 4096;

static mut INPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut OUTPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut PARAMS_BUF: [f32; 16] = [0.0; 16];
static mut TRANSPORT_BUF: [f32; 6] = [0.0; 6];

// Parameter indices
const SYNC: usize = 0;
const RATE: usize = 1;     // 0.5–20 Hz
const DIVISION: usize = 2; // 0–6
const DEPTH: usize = 3;    // 0.0–1.0

// Division mapping: 0=1/1, 1=1/2, 2=1/4, 3=1/8, 4=1/16, 5=1/4T, 6=1/8T
// Values are in beats (quarter notes)
const DIVISIONS: [f64; 7] = [4.0, 2.0, 1.0, 0.5, 0.25, 2.0 / 3.0, 1.0 / 3.0];

// Persistent phase across callbacks
// Use f64 to match Python's float64 precision in the phase accumulator.
static mut PHASE: f64 = 0.0;

static METADATA: &str = r#"[{"name":"Sync","min":0.0,"max":1.0,"unit":"","default":0.0},{"name":"Rate","min":0.5,"max":20.0,"unit":"Hz","default":5.0},{"name":"Division","min":0.0,"max":6.0,"unit":"","default":2.0},{"name":"Depth","min":0.0,"max":1.0,"unit":"","default":0.5}]"#;

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
pub extern "C" fn get_transport_ptr() -> i32 {
    unsafe { TRANSPORT_BUF.as_ptr() as i32 }
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
        let sync = PARAMS_BUF[SYNC] as f64;
        let depth = PARAMS_BUF[DEPTH] as f64;
        let tempo = TRANSPORT_BUF[0] as f64;

        // Determine LFO rate
        let rate_hz = if sync > 0.5 && tempo > 0.0 {
            let div_idx_raw = PARAMS_BUF[DIVISION] as f64;
            let div_idx = div_idx_raw.round() as usize;
            let div_idx = if div_idx >= DIVISIONS.len() { DIVISIONS.len() - 1 } else { div_idx };
            let beats = DIVISIONS[div_idx];
            tempo / 60.0 / beats
        } else {
            PARAMS_BUF[RATE] as f64
        };

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
