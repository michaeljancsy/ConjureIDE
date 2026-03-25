// Ping-Pong Delay — stereo bouncing echo.
//
// Creates echoes that alternate between left and right channels. The
// input feeds into the left delay, the left delay's output feeds into
// the right delay, and the right delay feeds back into the left. This
// creates a bouncing stereo effect. For mono input, falls back to a
// simple delay with feedback.
//
// Params:
//   0 (Time):     Delay time — 50 to 500 ms
//   1 (Feedback): Feedback amount — 0.0 to 0.95
//   2 (Mix):      Dry/wet mix — 0.0 to 1.0

const MAX_CH: usize = 2;
const MAX_FR: usize = 4096;
const MAX_DELAY: usize = 48000;

static mut INPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut OUTPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut PARAMS_BUF: [f32; 16] = [0.0; 16];

// Parameter indices
const TIME: usize = 0;     // 50–500 ms
const FEEDBACK: usize = 1; // 0.0–0.95
const MIX: usize = 2;      // 0.0–1.0

// Persistent state: separate left and right delay lines
static mut LEFT_BUF: [f32; MAX_DELAY] = [0.0; MAX_DELAY];
static mut RIGHT_BUF: [f32; MAX_DELAY] = [0.0; MAX_DELAY];
static mut WRITE_POS: usize = 0;

static METADATA: &str = r#"[{"name":"Time","min":50.0,"max":500.0,"unit":"ms","default":250.0},{"name":"Feedback","min":0.0,"max":0.95,"unit":"","default":0.5},{"name":"Mix","min":0.0,"max":1.0,"unit":"","default":0.5}]"#;

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

    unsafe {
        let delay_ms = PARAMS_BUF[TIME];
        let feedback = PARAMS_BUF[FEEDBACK];
        let mix = PARAMS_BUF[MIX];

        let mut delay_samples = (delay_ms * 0.001 * sample_rate) as usize;
        if delay_samples >= MAX_DELAY {
            delay_samples = MAX_DELAY - 1;
        }

        let inp = std::slice::from_raw_parts(input, ch * frames);
        let out = std::slice::from_raw_parts_mut(output, ch * frames);
        let mut wp = WRITE_POS;

        if ch < 2 {
            // Mono: simple delay with feedback
            for i in 0..frames {
                let rp = (wp + MAX_DELAY - delay_samples) % MAX_DELAY;
                let delayed = LEFT_BUF[rp];
                LEFT_BUF[wp] = inp[i] + delayed * feedback;
                out[i] = inp[i] * (1.0 - mix) + delayed * mix;
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
                LEFT_BUF[wp] = mono_in + right_delayed * feedback;
                RIGHT_BUF[wp] = left_delayed * feedback;

                // Mix dry + wet
                out[i] = inp[i] * (1.0 - mix) + left_delayed * mix;
                out[frames + i] = inp[frames + i] * (1.0 - mix) + right_delayed * mix;

                wp = (wp + 1) % MAX_DELAY;
            }
        }

        WRITE_POS = wp;
    }
}
