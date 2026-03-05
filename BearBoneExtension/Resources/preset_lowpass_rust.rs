// Low-Pass Filter — simple 1-pole IIR low-pass.
//
// Implements the simplest possible IIR low-pass filter:
//     y[n] = (1 - a) * x[n] + a * y[n-1]
// where a = exp(-2 * pi * cutoff / sample_rate).
// Rolls off at 6 dB/octave above the cutoff frequency.
// State is maintained per channel across callbacks.

const MAX_CH: usize = 2;
const MAX_FR: usize = 4096;

static mut INPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut OUTPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut PARAMS_BUF: [f32; 8] = [0.0; 8];

const CUTOFF_HZ: f64 = 800.0;

// Persistent state: previous output per channel
// Use f64 to match Python's float64 precision in the feedback loop.
static mut PREV_OUT: [f64; MAX_CH] = [0.0; MAX_CH];

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
    let a = (-two_pi * CUTOFF_HZ / sr).exp();
    let b = 1.0 - a;

    unsafe {
        let inp = std::slice::from_raw_parts(input, ch * frames);
        let out = std::slice::from_raw_parts_mut(output, ch * frames);

        for c in 0..ch {
            let mut y = PREV_OUT[c];
            for i in 0..frames {
                let idx = c * frames + i;
                y = b * inp[idx] as f64 + a * y;
                out[idx] = y as f32;
            }
            PREV_OUT[c] = y;
        }
    }
}
