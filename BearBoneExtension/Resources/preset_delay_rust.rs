// Simple Delay — echo effect with feedback.
//
// Delays the signal by a fixed time and feeds the delayed output back
// into the delay line. Each repeat is attenuated by the feedback amount,
// creating a decaying echo. The dry/wet mix controls the balance between
// the original signal and the delayed signal.

const MAX_CH: usize = 2;
const MAX_FR: usize = 4096;
const MAX_DELAY: usize = 48000;

static mut INPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut OUTPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut PARAMS_BUF: [f32; 8] = [0.0; 8];

const DELAY_MS: f32 = 250.0;
const FEEDBACK: f32 = 0.5;
const MIX: f32 = 0.5;

// Persistent state
static mut DELAY_BUF: [[f32; MAX_DELAY]; MAX_CH] = [[0.0; MAX_DELAY]; MAX_CH];
static mut WRITE_POS: usize = 0;

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
    let mut delay_samples = (DELAY_MS * 0.001 * sample_rate) as usize;
    if delay_samples >= MAX_DELAY {
        delay_samples = MAX_DELAY - 1;
    }

    unsafe {
        let inp = std::slice::from_raw_parts(input, ch * frames);
        let out = std::slice::from_raw_parts_mut(output, ch * frames);
        let mut wp = WRITE_POS;

        for i in 0..frames {
            let rp = (wp + MAX_DELAY - delay_samples) % MAX_DELAY;

            for c in 0..ch {
                let idx = c * frames + i;
                let delayed = DELAY_BUF[c][rp];

                // Write input + feedback to delay line
                DELAY_BUF[c][wp] = inp[idx] + delayed * FEEDBACK;

                // Mix dry + wet
                out[idx] = inp[idx] * (1.0 - MIX) + delayed * MIX;
            }

            wp = (wp + 1) % MAX_DELAY;
        }

        WRITE_POS = wp;
    }
}
