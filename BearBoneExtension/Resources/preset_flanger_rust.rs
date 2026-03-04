// Flanger — short modulated delay with feedback.
//
// Similar to chorus but with a much shorter delay (0–4 ms) and feedback.
// The short delay creates comb-filter effects, and the LFO sweeps the
// comb filter notches up and down, producing the characteristic flanging
// jet-plane sweep. Higher feedback intensifies the comb-filter peaks.

const MAX_CH: usize = 2;
const MAX_FR: usize = 4096;
const MAX_DELAY: usize = 1024;

static mut INPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut OUTPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut PARAMS_BUF: [f32; 8] = [0.0; 8];

const RATE_HZ: f32 = 0.3;
const DEPTH_MS: f32 = 2.0;
const BASE_DELAY_MS: f32 = 2.0;
const FEEDBACK: f32 = 0.7;
const MIX: f32 = 0.5;

// Persistent state
static mut DELAY_BUF: [[f32; MAX_DELAY]; MAX_CH] = [[0.0; MAX_DELAY]; MAX_CH];
static mut WRITE_POS: usize = 0;
static mut LFO_PHASE: f32 = 0.0;

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
    let lfo_inc = two_pi * RATE_HZ / sample_rate;

    unsafe {
        let inp = std::slice::from_raw_parts(input, ch * frames);
        let out = std::slice::from_raw_parts_mut(output, ch * frames);
        let mut phase = LFO_PHASE;
        let mut wp = WRITE_POS;

        for i in 0..frames {
            let delay_samples = (BASE_DELAY_MS + DEPTH_MS * phase.sin()) * sample_rate / 1000.0;

            for c in 0..ch {
                let idx = i * ch + c;

                // Read with linear interpolation
                let mut read_pos = wp as f32 - delay_samples;
                if read_pos < 0.0 {
                    read_pos += MAX_DELAY as f32;
                }
                let idx0 = (read_pos as usize) % MAX_DELAY;
                let idx1 = (idx0 + 1) % MAX_DELAY;
                let frac = read_pos - read_pos.floor();
                let delayed = DELAY_BUF[c][idx0] * (1.0 - frac) + DELAY_BUF[c][idx1] * frac;

                // Write input + feedback to delay line
                DELAY_BUF[c][wp] = inp[idx] + delayed * FEEDBACK;

                // Mix dry + wet
                out[idx] = inp[idx] * (1.0 - MIX) + delayed * MIX;
            }

            phase += lfo_inc;
            wp = (wp + 1) % MAX_DELAY;
        }

        LFO_PHASE = phase % two_pi;
        WRITE_POS = wp;
    }
}
