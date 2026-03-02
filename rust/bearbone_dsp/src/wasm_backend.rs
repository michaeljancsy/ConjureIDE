use crate::backend::Backend;
use wasmtime::*;

/// WASM DSP backend using wasmtime.
///
/// Loads a WASM module that exports a `process` function and `memory`.
/// Audio data is copied into/out of WASM linear memory each render callback.
///
/// The WASM `process` function signature:
///   `(input_ptr: i32, output_ptr: i32, channels: i32, frame_count: i32, sample_rate: f32) -> ()`
///
/// Memory layout at input_ptr / output_ptr:
///   Channels laid out sequentially, each `frame_count` floats.
///   `[ch0_f0, ch0_f1, ..., ch1_f0, ch1_f1, ...]`
pub struct WasmBackend {
    store: Store<()>,
    memory: Memory,
    process_fn: TypedFunc<(i32, i32, i32, i32, f32), ()>,
    input_offset: i32,
    output_offset: i32,
    channel_count: usize,
    max_frames: u32,
    fuel_per_callback: u64,
    last_error: Option<String>,
}

/// Base offset in WASM linear memory to avoid the null page.
const MEMORY_BASE: i32 = 1024;

/// Default fuel budget per audio callback (~1M instructions).
const DEFAULT_FUEL: u64 = 1_000_000;

impl WasmBackend {
    /// Load a WASM module from bytes.
    ///
    /// The module must export:
    /// - `memory`: linear memory
    /// - `process(i32, i32, i32, i32, f32) -> ()`: DSP function
    pub fn load(wasm_bytes: &[u8]) -> Result<Self, String> {
        let mut config = Config::new();
        config.consume_fuel(true);

        let engine = Engine::new(&config).map_err(|e| format!("Failed to create engine: {}", e))?;

        let module =
            Module::new(&engine, wasm_bytes).map_err(|e| format!("Invalid WASM module: {}", e))?;

        let mut store = Store::new(&engine, ());
        // Add initial fuel for module instantiation
        store
            .set_fuel(DEFAULT_FUEL)
            .map_err(|e| format!("Failed to set fuel: {}", e))?;

        let instance = Instance::new(&mut store, &module, &[])
            .map_err(|e| format!("Failed to instantiate module: {}", e))?;

        let memory = instance
            .get_memory(&mut store, "memory")
            .ok_or_else(|| "Module does not export 'memory'".to_string())?;

        let process_fn = instance
            .get_typed_func::<(i32, i32, i32, i32, f32), ()>(&mut store, "process")
            .map_err(|e| format!("Module does not export a valid 'process' function: {}", e))?;

        Ok(Self {
            store,
            memory,
            process_fn,
            input_offset: 0,
            output_offset: 0,
            channel_count: 0,
            max_frames: 0,
            fuel_per_callback: DEFAULT_FUEL,
            last_error: None,
        })
    }
}

impl Backend for WasmBackend {
    fn initialize(&mut self, channel_count: usize, _sample_rate: f64, max_frames: u32) {
        self.channel_count = channel_count;
        self.max_frames = max_frames;

        // Calculate buffer sizes
        let bytes_per_buffer = channel_count * max_frames as usize * std::mem::size_of::<f32>();
        let total_needed = MEMORY_BASE as usize + bytes_per_buffer * 2;

        // Grow memory if needed (WASM pages are 64KiB)
        let current_bytes = self.memory.data_size(&self.store);
        if total_needed > current_bytes {
            let pages_needed =
                ((total_needed - current_bytes) + 65535) / 65536; // ceil division
            if let Err(e) = self.memory.grow(&mut self.store, pages_needed as u64) {
                eprintln!("BearBone-WASM: Failed to grow memory: {}", e);
                self.last_error = Some(format!("Failed to grow WASM memory: {}", e));
                return;
            }
        }

        self.input_offset = MEMORY_BASE;
        self.output_offset = MEMORY_BASE + bytes_per_buffer as i32;
    }

    fn deinitialize(&mut self) {
        // Nothing to free — WASM linear memory is managed by the engine.
        self.channel_count = 0;
        self.max_frames = 0;
        self.input_offset = 0;
        self.output_offset = 0;
    }

    unsafe fn process(
        &mut self,
        inputs: &[*const f32],
        outputs: &[*mut f32],
        channel_count: usize,
        frame_count: usize,
        sample_rate: f64,
    ) -> bool {
        if self.input_offset == 0 || channel_count == 0 || frame_count == 0 {
            return false;
        }

        // Refuel the store for this callback
        if let Err(e) = self.store.set_fuel(self.fuel_per_callback) {
            self.last_error = Some(format!("Failed to set fuel: {}", e));
            return false;
        }

        let mem_data = self.memory.data_mut(&mut self.store);

        // Copy input audio into WASM linear memory
        let input_byte_offset = self.input_offset as usize;
        for ch in 0..channel_count {
            let src = std::slice::from_raw_parts(inputs[ch], frame_count);
            let dst_offset = input_byte_offset + ch * frame_count * 4;
            let dst = &mut mem_data[dst_offset..dst_offset + frame_count * 4];
            // Copy f32 samples as raw bytes
            for (i, &sample) in src.iter().enumerate() {
                dst[i * 4..(i + 1) * 4].copy_from_slice(&sample.to_le_bytes());
            }
        }

        // Call the WASM process function
        let result = self.process_fn.call(
            &mut self.store,
            (
                self.input_offset,
                self.output_offset,
                channel_count as i32,
                frame_count as i32,
                sample_rate as f32,
            ),
        );

        if let Err(e) = result {
            self.last_error = Some(format!("WASM process error: {}", e));
            return false;
        }

        // Copy output audio from WASM linear memory
        let mem_data = self.memory.data(&self.store);
        let output_byte_offset = self.output_offset as usize;
        for ch in 0..channel_count {
            let dst = std::slice::from_raw_parts_mut(outputs[ch], frame_count);
            let src_offset = output_byte_offset + ch * frame_count * 4;
            let src = &mem_data[src_offset..src_offset + frame_count * 4];
            for i in 0..frame_count {
                dst[i] = f32::from_le_bytes([
                    src[i * 4],
                    src[i * 4 + 1],
                    src[i * 4 + 2],
                    src[i * 4 + 3],
                ]);
            }
        }

        true
    }

    fn last_error(&self) -> Option<&str> {
        self.last_error.as_deref()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// WAT module that applies 0.5x gain to all samples.
    const GAIN_HALF_WAT: &str = r#"
        (module
          (memory (export "memory") 1)
          (func (export "process")
            (param $in i32) (param $out i32) (param $ch i32) (param $frames i32) (param $sr f32)
            (local $i i32)
            (local $total i32)
            (local.set $total (i32.mul (local.get $ch) (local.get $frames)))
            (block $break
              (loop $loop
                (br_if $break (i32.ge_u (local.get $i) (local.get $total)))
                (f32.store
                  (i32.add (local.get $out) (i32.shl (local.get $i) (i32.const 2)))
                  (f32.mul
                    (f32.load (i32.add (local.get $in) (i32.shl (local.get $i) (i32.const 2))))
                    (f32.const 0.5)
                  )
                )
                (local.set $i (i32.add (local.get $i) (i32.const 1)))
                (br $loop)
              )
            )
          )
        )
    "#;

    /// WAT module that copies input to output (passthrough).
    const PASSTHROUGH_WAT: &str = r#"
        (module
          (memory (export "memory") 1)
          (func (export "process")
            (param $in i32) (param $out i32) (param $ch i32) (param $frames i32) (param $sr f32)
            (local $i i32)
            (local $total i32)
            (local.set $total (i32.mul (local.get $ch) (local.get $frames)))
            (block $break
              (loop $loop
                (br_if $break (i32.ge_u (local.get $i) (local.get $total)))
                (f32.store
                  (i32.add (local.get $out) (i32.shl (local.get $i) (i32.const 2)))
                  (f32.load (i32.add (local.get $in) (i32.shl (local.get $i) (i32.const 2))))
                )
                (local.set $i (i32.add (local.get $i) (i32.const 1)))
                (br $loop)
              )
            )
          )
        )
    "#;

    /// WAT module with an infinite loop (for fuel exhaustion testing).
    const INFINITE_LOOP_WAT: &str = r#"
        (module
          (memory (export "memory") 1)
          (func (export "process")
            (param $in i32) (param $out i32) (param $ch i32) (param $frames i32) (param $sr f32)
            (loop $forever
              (br $forever)
            )
          )
        )
    "#;

    /// WAT module without memory export.
    const NO_MEMORY_WAT: &str = r#"
        (module
          (memory 1)
          (func (export "process")
            (param $in i32) (param $out i32) (param $ch i32) (param $frames i32) (param $sr f32)
          )
        )
    "#;

    /// WAT module without process export.
    const NO_PROCESS_WAT: &str = r#"
        (module
          (memory (export "memory") 1)
          (func (export "not_process")
            (param $in i32) (param $out i32) (param $ch i32) (param $frames i32) (param $sr f32)
          )
        )
    "#;

    /// Helper: compile WAT text to WASM bytes.
    fn wat_to_wasm(wat: &str) -> Vec<u8> {
        wat::parse_str(wat).expect("Failed to parse WAT")
    }

    // --- Tests ---

    #[test]
    fn test_wasm_load_gain() {
        let wasm = wat_to_wasm(GAIN_HALF_WAT);
        let backend = WasmBackend::load(&wasm);
        assert!(backend.is_ok(), "Should load valid WASM: {:?}", backend.err());
    }

    #[test]
    fn test_wasm_process_gain_mono() {
        let wasm = wat_to_wasm(GAIN_HALF_WAT);
        let mut backend = WasmBackend::load(&wasm).unwrap();
        backend.initialize(1, 44100.0, 1024);

        let input: [f32; 4] = [1.0, 0.5, -1.0, 0.0];
        let mut output: [f32; 4] = [0.0; 4];

        let ok = unsafe {
            backend.process(
                &[input.as_ptr()],
                &[output.as_mut_ptr()],
                1,
                4,
                44100.0,
            )
        };
        assert!(ok, "process should succeed");
        assert_eq!(output, [0.5, 0.25, -0.5, 0.0]);
    }

    #[test]
    fn test_wasm_process_gain_stereo() {
        let wasm = wat_to_wasm(GAIN_HALF_WAT);
        let mut backend = WasmBackend::load(&wasm).unwrap();
        backend.initialize(2, 44100.0, 1024);

        let input_l: [f32; 4] = [1.0, 0.5, -1.0, 0.0];
        let input_r: [f32; 4] = [0.2, 0.4, 0.6, 0.8];
        let mut output_l: [f32; 4] = [0.0; 4];
        let mut output_r: [f32; 4] = [0.0; 4];

        let ok = unsafe {
            backend.process(
                &[input_l.as_ptr(), input_r.as_ptr()],
                &[output_l.as_mut_ptr(), output_r.as_mut_ptr()],
                2,
                4,
                44100.0,
            )
        };
        assert!(ok, "process should succeed");
        assert_eq!(output_l, [0.5, 0.25, -0.5, 0.0]);
        assert_eq!(output_r, [0.1, 0.2, 0.3, 0.4]);
    }

    #[test]
    fn test_wasm_passthrough() {
        let wasm = wat_to_wasm(PASSTHROUGH_WAT);
        let mut backend = WasmBackend::load(&wasm).unwrap();
        backend.initialize(1, 44100.0, 1024);

        let input: [f32; 4] = [0.1, 0.2, 0.3, 0.4];
        let mut output: [f32; 4] = [0.0; 4];

        let ok = unsafe {
            backend.process(
                &[input.as_ptr()],
                &[output.as_mut_ptr()],
                1,
                4,
                44100.0,
            )
        };
        assert!(ok);
        assert_eq!(output, [0.1, 0.2, 0.3, 0.4]);
    }

    #[test]
    fn test_wasm_invalid_bytes() {
        let result = WasmBackend::load(b"not a wasm module");
        assert!(result.is_err());
        let err = result.err().unwrap();
        assert!(
            err.contains("Invalid WASM module"),
            "Error should mention invalid module: {}",
            err
        );
    }

    #[test]
    fn test_wasm_missing_process_export() {
        let wasm = wat_to_wasm(NO_PROCESS_WAT);
        let result = WasmBackend::load(&wasm);
        assert!(result.is_err());
        let err = result.err().unwrap();
        assert!(
            err.contains("process"),
            "Error should mention missing process: {}",
            err
        );
    }

    #[test]
    fn test_wasm_missing_memory_export() {
        let wasm = wat_to_wasm(NO_MEMORY_WAT);
        let result = WasmBackend::load(&wasm);
        assert!(result.is_err());
        let err = result.err().unwrap();
        assert!(
            err.contains("memory"),
            "Error should mention missing memory: {}",
            err
        );
    }

    #[test]
    fn test_wasm_fuel_exhaustion() {
        let wasm = wat_to_wasm(INFINITE_LOOP_WAT);
        let mut backend = WasmBackend::load(&wasm).unwrap();
        backend.initialize(1, 44100.0, 1024);

        let input: [f32; 4] = [1.0, 0.5, -1.0, 0.0];
        let mut output: [f32; 4] = [0.0; 4];

        let ok = unsafe {
            backend.process(
                &[input.as_ptr()],
                &[output.as_mut_ptr()],
                1,
                4,
                44100.0,
            )
        };
        assert!(!ok, "Infinite loop should fail due to fuel exhaustion");
        assert!(
            backend.last_error().is_some(),
            "Should have an error message"
        );
    }

    #[test]
    fn test_wasm_process_before_initialize_returns_false() {
        let wasm = wat_to_wasm(GAIN_HALF_WAT);
        let mut backend = WasmBackend::load(&wasm).unwrap();
        // Don't call initialize

        let input: [f32; 4] = [1.0; 4];
        let mut output: [f32; 4] = [0.0; 4];

        let ok = unsafe {
            backend.process(
                &[input.as_ptr()],
                &[output.as_mut_ptr()],
                1,
                4,
                44100.0,
            )
        };
        assert!(!ok, "Should fail without initialize");
    }

    #[test]
    fn test_wasm_initialize_deinitialize_cycle() {
        let wasm = wat_to_wasm(GAIN_HALF_WAT);
        let mut backend = WasmBackend::load(&wasm).unwrap();

        for _ in 0..3 {
            backend.initialize(2, 48000.0, 512);

            let input: [f32; 4] = [1.0; 4];
            let mut output: [f32; 4] = [0.0; 4];
            let ok = unsafe {
                backend.process(
                    &[input.as_ptr()],
                    &[output.as_mut_ptr()],
                    1,
                    4,
                    48000.0,
                )
            };
            assert!(ok);
            assert_eq!(output, [0.5; 4]);

            backend.deinitialize();
        }
    }

    #[test]
    fn test_wasm_multiple_callbacks() {
        let wasm = wat_to_wasm(GAIN_HALF_WAT);
        let mut backend = WasmBackend::load(&wasm).unwrap();
        backend.initialize(1, 44100.0, 1024);

        // Call process multiple times (simulating audio stream)
        for i in 0..10 {
            let val = (i as f32 + 1.0) * 0.1;
            let input: [f32; 4] = [val; 4];
            let mut output: [f32; 4] = [0.0; 4];

            let ok = unsafe {
                backend.process(
                    &[input.as_ptr()],
                    &[output.as_mut_ptr()],
                    1,
                    4,
                    44100.0,
                )
            };
            assert!(ok, "Callback {} should succeed", i);
            for &s in &output {
                assert!(
                    (s - val * 0.5).abs() < 1e-6,
                    "Expected {} got {} on callback {}",
                    val * 0.5,
                    s,
                    i
                );
            }
        }
    }
}
