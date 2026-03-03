// Tremolo — sine-based amplitude modulation.

const MAX_CH: usize = 2;
const MAX_FR: usize = 4096;

static mut INPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut OUTPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];

// Tremolo parameters
const RATE_HZ: f32 = 4.0;
const DEPTH: f32 = 0.5; // 0.0 = no effect, 1.0 = full tremolo

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
    let phase_inc = two_pi * RATE_HZ / sample_rate;

    unsafe {
        let inp = std::slice::from_raw_parts(input, ch * frames);
        let out = std::slice::from_raw_parts_mut(output, ch * frames);
        let mut phase = PHASE;

        for i in 0..frames {
            let lfo = 1.0 - DEPTH * 0.5 * (1.0 + (phase).sin());
            for c in 0..ch {
                let idx = i * ch + c;
                out[idx] = inp[idx] * lfo;
            }
            phase += phase_inc;
        }

        PHASE = phase % two_pi;
    }
}
