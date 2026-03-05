// Gain + Pan — volume control with stereo panning.
//
// Applies a fixed gain (in dB) and constant-power panning to the signal.
// Panning uses a sine/cosine law for constant power across the stereo
// field. For mono signals, only gain is applied (panning has no effect
// with a single channel).

const MAX_CH: usize = 2;
const MAX_FR: usize = 4096;

static mut INPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut OUTPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut PARAMS_BUF: [f32; 8] = [0.0; 8];

const GAIN_DB: f32 = -6.0;
const PAN: f32 = 0.75; // 0.0 = hard left, 0.5 = center, 1.0 = hard right

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
    _sample_rate: f32,
) {
    let ch = channels as usize;
    let frames = frame_count as usize;
    let gain = (10.0_f32).powf(GAIN_DB / 20.0);
    let half_pi = core::f32::consts::PI * 0.5;

    unsafe {
        let inp = std::slice::from_raw_parts(input, ch * frames);
        let out = std::slice::from_raw_parts_mut(output, ch * frames);

        if ch == 1 {
            for i in 0..frames {
                out[i] = inp[i] * gain;
            }
        } else {
            let left_gain = gain * (PAN * half_pi).cos();
            let right_gain = gain * (PAN * half_pi).sin();
            for i in 0..frames {
                out[i] = inp[i] * left_gain;
                out[frames + i] = inp[frames + i] * right_gain;
            }
        }
    }
}
