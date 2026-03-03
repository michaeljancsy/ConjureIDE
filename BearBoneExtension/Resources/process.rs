// BearBone DSP — Rust Template
//
// This script is compiled to WebAssembly and runs in the audio render callback.
// The `process` function is called once per audio buffer.
//
// Safety: avoid allocations, I/O, or panics in `process()`.

const MAX_CH: usize = 2;
const MAX_FR: usize = 4096;

static mut INPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
static mut OUTPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];

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
    _sample_rate: f32,
) {
    let n = (channels * frame_count) as usize;
    unsafe {
        let inp = std::slice::from_raw_parts(input, n);
        let out = std::slice::from_raw_parts_mut(output, n);
        for i in 0..n {
            out[i] = inp[i]; // passthrough — replace with your DSP
        }
    }
}
