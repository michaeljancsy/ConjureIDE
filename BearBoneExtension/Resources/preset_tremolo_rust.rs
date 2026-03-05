// Tremolo — sine-based amplitude modulation.
//
// Modulates the audio amplitude with a low-frequency sine oscillator (LFO).
// The LFO phase is tracked across callbacks for seamless modulation.
// At DEPTH=0.0 the signal passes through unchanged; at DEPTH=1.0 the signal
// fades fully to silence at the LFO troughs.

const MAX_CH: usize = 2;
const MAX_FR: usize = 4096;

static mut INPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut OUTPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut PARAMS_BUF: [f32; 8] = [0.0; 8];

// Tremolo parameters
const RATE_HZ: f64 = 4.0;
const DEPTH: f64 = 0.5; // 0.0 = no effect, 1.0 = full tremolo

// Persistent phase across callbacks
// Use f64 to match Python's float64 precision in the phase accumulator.
static mut PHASE: f64 = 0.0;

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

/// Tremolo — sine-based amplitude modulation.
///
/// Computes a per-sample LFO gain using a sine wave at RATE_HZ, then multiplies
/// each input sample by that gain. The phase accumulates across callbacks so the
/// modulation is seamless between audio buffers. All channels share the same LFO.
/// DAW-automatable parameters are available in PARAMS_BUF[0..8] but unused by
/// this preset.
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
    let phase_inc = two_pi * RATE_HZ / sr;

    unsafe {
        let inp = std::slice::from_raw_parts(input, ch * frames);
        let out = std::slice::from_raw_parts_mut(output, ch * frames);
        let mut phase = PHASE;

        for i in 0..frames {
            let lfo = 1.0 - DEPTH * 0.5 * (1.0 + phase.sin());
            for c in 0..ch {
                let idx = c * frames + i;
                out[idx] = (inp[idx] as f64 * lfo) as f32;
            }
            phase += phase_inc;
        }

        PHASE = phase % two_pi;
    }
}
