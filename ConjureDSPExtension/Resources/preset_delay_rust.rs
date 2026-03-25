// Simple Delay — echo effect with feedback.
//
// Delays the signal by a fixed time and feeds the delayed output back
// into the delay line. Each repeat is attenuated by the feedback amount,
// creating a decaying echo. The dry/wet mix controls the balance between
// the original signal and the delayed signal.
//
// Params:
//   0 (Time):     Delay time — 10 to 500 ms
//   1 (Feedback): Feedback amount — 0.0 to 0.95
//   2 (Mix):      Dry/wet mix — 0.0 to 1.0

const MAX_CH: usize = 2;
const MAX_FR: usize = 4096;
const MAX_DELAY: usize = 48000;

static mut INPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut OUTPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut PARAMS_BUF: [f32; 16] = [0.0; 16];

// Parameter indices
const TIME: usize = 0;     // 10–500 ms
const FEEDBACK: usize = 1; // 0.0–0.95
const MIX: usize = 2;      // 0.0–1.0

// Persistent state
static mut DELAY_BUF: [[f32; MAX_DELAY]; MAX_CH] = [[0.0; MAX_DELAY]; MAX_CH];
static mut WRITE_POS: usize = 0;

static METADATA: &str = r#"[{"name":"Time","min":10.0,"max":500.0,"unit":"ms","default":250.0},{"name":"Feedback","min":0.0,"max":0.95,"unit":"","default":0.5},{"name":"Mix","min":0.0,"max":1.0,"unit":"","default":0.5}]"#;

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

        for i in 0..frames {
            let rp = (wp + MAX_DELAY - delay_samples) % MAX_DELAY;

            for c in 0..ch {
                let idx = c * frames + i;
                let delayed = DELAY_BUF[c][rp];

                // Write input + feedback to delay line
                DELAY_BUF[c][wp] = inp[idx] + delayed * feedback;

                // Mix dry + wet
                out[idx] = inp[idx] * (1.0 - mix) + delayed * mix;
            }

            wp = (wp + 1) % MAX_DELAY;
        }

        WRITE_POS = wp;
    }
}
