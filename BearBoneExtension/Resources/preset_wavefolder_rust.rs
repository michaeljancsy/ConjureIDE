// Wavefolder — folds the waveform back when it exceeds +/-1.
//
// Applies gain (drive) to the input, then uses triangle-wave wrapping
// to fold the signal back into the +/-1 range. Each fold reflects the
// waveform, producing increasingly rich harmonic content as drive increases.
// Unlike clipping, wavefolding preserves energy and creates a distinctive
// metallic/buzzy timbre popular in modular synthesis.
//
// Params:
//   0 (Drive): Fold drive — 1.0 to 20.0

const MAX_CH: usize = 2;
const MAX_FR: usize = 4096;

static mut INPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut OUTPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut PARAMS_BUF: [f32; 16] = [0.0; 16];

// Parameter indices
const DRIVE: usize = 0; // 1.0–20.0

static METADATA: &str = r#"[{"name":"Drive","min":1.0,"max":20.0,"unit":"","default":5.0}]"#;

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
    _sample_rate: f32,
) {
    let ch = channels as usize;
    let frames = frame_count as usize;

    unsafe {
        let drive = PARAMS_BUF[DRIVE];
        let inp = std::slice::from_raw_parts(input, ch * frames);
        let out = std::slice::from_raw_parts_mut(output, ch * frames);

        for c in 0..ch {
            for i in 0..frames {
                let idx = c * frames + i;
                let x = inp[idx] * drive;
                // Triangle-wave fold: maps any value into [-1, 1]
                let t = (x + 1.0) * 0.25;
                let t = t - t.floor();
                out[idx] = 1.0 - (t * 4.0 - 2.0).abs();
            }
        }
    }
}
