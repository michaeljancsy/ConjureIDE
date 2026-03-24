// Reverse Slicer — records chunks and plays them backwards.
//
// Divides the audio into fixed-length chunks. While recording each new
// chunk, the previous chunk is played back in reverse. This creates a
// glitchy, backwards effect where every CHUNK_MS milliseconds the audio
// reverses direction. Uses double-buffering: one buffer records while
// the other plays back reversed.
//
// Params:
//   0 (Rate): Chunk length — 10 to 500 ms

const MAX_CH: usize = 2;
const MAX_FR: usize = 4096;
const MAX_CHUNK: usize = 19200;

static mut INPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut OUTPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut PARAMS_BUF: [f32; 16] = [0.0; 16];

// Parameter indices
const RATE: usize = 0; // 10–500 ms

// Double buffers for record and playback
static mut BUF_A: [[f32; MAX_CHUNK]; MAX_CH] = [[0.0; MAX_CHUNK]; MAX_CH];
static mut BUF_B: [[f32; MAX_CHUNK]; MAX_CH] = [[0.0; MAX_CHUNK]; MAX_CH];
static mut RECORDING_A: bool = true; // true = recording to A, playing from B
static mut WRITE_POS: usize = 0;

static METADATA: &str = r#"[{"name":"Rate","min":10.0,"max":500.0,"unit":"ms","default":100.0}]"#;

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
        let chunk_ms = PARAMS_BUF[RATE];
        let mut chunk_size = (chunk_ms * 0.001 * sample_rate) as usize;
        if chunk_size > MAX_CHUNK {
            chunk_size = MAX_CHUNK;
        }

        let inp = std::slice::from_raw_parts(input, ch * frames);
        let out = std::slice::from_raw_parts_mut(output, ch * frames);
        let mut wp = WRITE_POS;

        for i in 0..frames {
            let read_pos = chunk_size - 1 - wp;

            for c in 0..ch {
                let idx = c * frames + i;

                if RECORDING_A {
                    // Record to A, play from B
                    BUF_A[c][wp] = inp[idx];
                    out[idx] = BUF_B[c][read_pos];
                } else {
                    // Record to B, play from A
                    BUF_B[c][wp] = inp[idx];
                    out[idx] = BUF_A[c][read_pos];
                }
            }

            wp += 1;
            if wp >= chunk_size {
                // Swap buffers
                RECORDING_A = !RECORDING_A;
                wp = 0;
            }
        }

        WRITE_POS = wp;
    }
}
