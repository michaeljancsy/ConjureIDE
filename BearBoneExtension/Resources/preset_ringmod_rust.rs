// Ring Modulator — multiplies the signal by a sine-wave carrier.
//
// Multiplies the input signal by a sine wave at the carrier frequency.
// This creates sum and difference frequencies, producing metallic,
// bell-like, or robotic timbres. Unlike tremolo (which modulates
// amplitude around a bias), ring modulation has no DC offset, so the
// carrier frequency components are always present in the output.

const MAX_CH: usize = 2;
const MAX_FR: usize = 4096;

static mut INPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut OUTPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut PARAMS_BUF: [f32; 8] = [0.0; 8];

const CARRIER_HZ: f64 = 440.0;

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
    let phase_inc = two_pi * CARRIER_HZ / sr;

    unsafe {
        let inp = std::slice::from_raw_parts(input, ch * frames);
        let out = std::slice::from_raw_parts_mut(output, ch * frames);
        let phase_start = PHASE;

        // Match Python's vectorized pattern: compute carrier from absolute
        // time within the chunk rather than accumulating phase per-sample.
        // This avoids floating-point drift from per-sample phase addition.
        for i in 0..frames {
            let t = (i as f64) / sr;
            let carrier = (two_pi * CARRIER_HZ * t + phase_start).sin();
            for c in 0..ch {
                let idx = c * frames + i;
                out[idx] = (inp[idx] as f64 * carrier) as f32;
            }
        }

        PHASE = (phase_start + two_pi * CARRIER_HZ * (frames as f64) / sr) % two_pi;
    }
}
