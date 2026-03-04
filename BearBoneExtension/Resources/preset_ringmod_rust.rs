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

const CARRIER_HZ: f32 = 440.0;

// Persistent phase across callbacks
static mut PHASE: f32 = 0.0;

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
    let two_pi = 2.0 * core::f32::consts::PI;
    let phase_inc = two_pi * CARRIER_HZ / sample_rate;

    unsafe {
        let inp = std::slice::from_raw_parts(input, ch * frames);
        let out = std::slice::from_raw_parts_mut(output, ch * frames);
        let mut phase = PHASE;

        for i in 0..frames {
            let carrier = phase.sin();
            for c in 0..ch {
                let idx = i * ch + c;
                out[idx] = inp[idx] * carrier;
            }
            phase += phase_inc;
        }

        PHASE = phase % two_pi;
    }
}
