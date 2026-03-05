// Ping-Pong Delay — stereo bouncing echo.
//
// Creates echoes that alternate between left and right channels. The
// input feeds into the left delay, the left delay's output feeds into
// the right delay, and the right delay feeds back into the left. This
// creates a bouncing stereo effect. For mono input, falls back to a
// simple delay with feedback.

const MAX_CH: usize = 2;
const MAX_FR: usize = 4096;
const MAX_DELAY: usize = 48000;

static mut INPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut OUTPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut PARAMS_BUF: [f32; 8] = [0.0; 8];

const DELAY_MS: f32 = 375.0;
const FEEDBACK: f32 = 0.4;
const MIX: f32 = 0.5;

// Persistent state: separate left and right delay lines
static mut LEFT_BUF: [f32; MAX_DELAY] = [0.0; MAX_DELAY];
static mut RIGHT_BUF: [f32; MAX_DELAY] = [0.0; MAX_DELAY];
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

        if ch < 2 {
            // Mono: simple delay with feedback
            for i in 0..frames {
                let rp = (wp + MAX_DELAY - delay_samples) % MAX_DELAY;
                let delayed = LEFT_BUF[rp];
                LEFT_BUF[wp] = inp[i] + delayed * FEEDBACK;
                out[i] = inp[i] * (1.0 - MIX) + delayed * MIX;
                wp = (wp + 1) % MAX_DELAY;
            }
        } else {
            // Stereo: ping-pong
            for i in 0..frames {
                let rp = (wp + MAX_DELAY - delay_samples) % MAX_DELAY;

                let left_delayed = LEFT_BUF[rp];
                let right_delayed = RIGHT_BUF[rp];

                // Input goes to left, left feeds right, right feeds back to left
                let mono_in = (inp[i] + inp[frames + i]) * 0.5;
                LEFT_BUF[wp] = mono_in + right_delayed * FEEDBACK;
                RIGHT_BUF[wp] = left_delayed * FEEDBACK;

                // Mix dry + wet
                out[i] = inp[i] * (1.0 - MIX) + left_delayed * MIX;
                out[frames + i] = inp[frames + i] * (1.0 - MIX) + right_delayed * MIX;

                wp = (wp + 1) % MAX_DELAY;
            }
        }

        WRITE_POS = wp;
    }
}
