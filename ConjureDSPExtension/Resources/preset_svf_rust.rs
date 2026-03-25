// Resonant State Variable Filter — multi-mode SVF (LP/HP/BP/Notch).
//
// Implements a digital state variable filter with low-pass output.
// The filter computes low-pass, high-pass, and band-pass simultaneously.
// Resonance controls the sharpness of the peak at the cutoff frequency.
// Change MODE constant to select output: 0=LP, 1=HP, 2=BP, 3=Notch.
//
// Params:
//   0 (Cutoff):    Filter cutoff — 20 to 20000 Hz (log)
//   1 (Resonance): Resonance Q — 0.5 to 10.0

const MAX_CH: usize = 2;
const MAX_FR: usize = 4096;

static mut INPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut OUTPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut PARAMS_BUF: [f32; 16] = [0.0; 16];

// Parameter indices
const CUTOFF: usize = 0;    // 20–20000 Hz
const RESONANCE: usize = 1; // 0.5–10.0

const MODE: usize = 0; // 0=LP, 1=HP, 2=BP, 3=Notch

// Persistent state per channel: [low, band]
// Use f64 to match Python's float64 precision in the coupled feedback loop.
static mut STATE_LOW: [f64; MAX_CH] = [0.0; MAX_CH];
static mut STATE_BAND: [f64; MAX_CH] = [0.0; MAX_CH];

static METADATA: &str = r#"[{"name":"Cutoff","min":20.0,"max":20000.0,"unit":"Hz","default":1000.0,"curve":"log"},{"name":"Resonance","min":0.5,"max":10.0,"unit":"","default":1.0}]"#;

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
    let sr = sample_rate as f64;

    unsafe {
        let cutoff_hz = PARAMS_BUF[CUTOFF] as f64;
        let resonance = PARAMS_BUF[RESONANCE] as f64;

        let f = 2.0 * (core::f64::consts::PI * cutoff_hz / sr).sin();
        let q = 1.0 / resonance;
        let inp = std::slice::from_raw_parts(input, ch * frames);
        let out = std::slice::from_raw_parts_mut(output, ch * frames);

        for c in 0..ch {
            let mut low = STATE_LOW[c];
            let mut band = STATE_BAND[c];

            for i in 0..frames {
                let idx = c * frames + i;
                let x = inp[idx] as f64;
                low += f * band;
                let high = x - low - q * band;
                band += f * high;

                out[idx] = match MODE {
                    0 => low as f32,
                    1 => high as f32,
                    2 => band as f32,
                    _ => (low + high) as f32, // notch
                };
            }

            STATE_LOW[c] = low;
            STATE_BAND[c] = band;
        }
    }
}
