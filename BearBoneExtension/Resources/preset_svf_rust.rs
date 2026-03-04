// Resonant State Variable Filter — multi-mode SVF (LP/HP/BP/Notch).
//
// Implements a digital state variable filter with low-pass output.
// The filter computes low-pass, high-pass, and band-pass simultaneously.
// Resonance controls the sharpness of the peak at the cutoff frequency.
// Change MODE constant to select output: 0=LP, 1=HP, 2=BP, 3=Notch.

const MAX_CH: usize = 2;
const MAX_FR: usize = 4096;

static mut INPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut OUTPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut PARAMS_BUF: [f32; 8] = [0.0; 8];

const CUTOFF_HZ: f32 = 1000.0;
const RESONANCE: f32 = 2.0;
const MODE: usize = 0; // 0=LP, 1=HP, 2=BP, 3=Notch

// Persistent state per channel: [low, band]
static mut STATE_LOW: [f32; MAX_CH] = [0.0; MAX_CH];
static mut STATE_BAND: [f32; MAX_CH] = [0.0; MAX_CH];

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
    let f = 2.0 * (core::f32::consts::PI * CUTOFF_HZ / sample_rate).sin();
    let q = 1.0 / RESONANCE;

    unsafe {
        let inp = std::slice::from_raw_parts(input, ch * frames);
        let out = std::slice::from_raw_parts_mut(output, ch * frames);

        for c in 0..ch {
            let mut low = STATE_LOW[c];
            let mut band = STATE_BAND[c];

            for i in 0..frames {
                let idx = i * ch + c;
                let x = inp[idx];
                low += f * band;
                let high = x - low - q * band;
                band += f * high;

                out[idx] = match MODE {
                    0 => low,
                    1 => high,
                    2 => band,
                    _ => low + high, // notch
                };
            }

            STATE_LOW[c] = low;
            STATE_BAND[c] = band;
        }
    }
}
