use crate::backend::Backend;
use crate::params::PARAM_COUNT;
use std::collections::HashMap;
use wasmtime::*;

/// How I/O buffer addresses are determined in WASM memory.
enum BufferMode {
    /// Backend chooses fixed offsets (for hand-written WAT modules without getters).
    FixedOffset,
    /// Module exports `get_input_ptr()`/`get_output_ptr()` that return buffer addresses.
    /// Used by compiled Rust/C modules whose memory layout is managed by the compiler.
    ModuleAllocated,
}

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
///
/// Compiled modules (Rust/C targeting wasm32-wasip1) should export `get_input_ptr()` and
/// `get_output_ptr()` functions that return the addresses of pre-allocated static buffers.
/// This avoids memory layout conflicts with the compiler's stack/heap.
pub struct WasmBackend {
    store: Store<()>,
    memory: Memory,
    process_fn: TypedFunc<(i32, i32, i32, i32, f32), ()>,
    get_input_ptr_fn: Option<TypedFunc<(), i32>>,
    get_output_ptr_fn: Option<TypedFunc<(), i32>>,
    get_params_ptr_fn: Option<TypedFunc<(), i32>>,
    buffer_mode: BufferMode,
    input_offset: i32,
    output_offset: i32,
    params_offset: i32,
    channel_count: usize,
    max_frames: u32,
    fuel_per_callback: u64,
    last_error: Option<String>,
    param_names: HashMap<u8, String>,
    param_metadata: Option<Vec<crate::params::ParamMetadata>>,
    /// How many params to write to WASM memory. Defaults to 8 for backward compat
    /// with existing modules that allocate `[f32; 8]`. Modules with rich metadata
    /// may declare more.
    param_write_count: usize,
}

/// Base offset in WASM linear memory to avoid the null page.
const MEMORY_BASE: i32 = 1024;

/// Default fuel budget per audio callback (~1M instructions) for hand-written WAT.
const DEFAULT_FUEL: u64 = 1_000_000;

/// Higher fuel budget for compiled modules (Rust/C via wasm32-wasip1).
/// Compiled code includes musl overhead, bounds checking, etc.
const COMPILED_FUEL: u64 = 10_000_000;

impl WasmBackend {
    /// Load a WASM module from bytes.
    ///
    /// The module must export:
    /// - `memory`: linear memory
    /// - `process(i32, i32, i32, i32, f32) -> ()`: DSP function
    ///
    /// Optionally, the module may export:
    /// - `get_input_ptr() -> i32`: returns address of pre-allocated input buffer
    /// - `get_output_ptr() -> i32`: returns address of pre-allocated output buffer
    ///
    /// WASI preview1 imports are automatically stubbed for compiled modules.
    pub fn load(wasm_bytes: &[u8]) -> Result<Self, String> {
        let mut config = Config::new();
        config.consume_fuel(true);

        let engine = Engine::new(&config).map_err(|e| format!("Failed to create engine: {}", e))?;

        let module =
            Module::new(&engine, wasm_bytes).map_err(|e| format!("Invalid WASM module: {}", e))?;

        let mut store = Store::new(&engine, ());
        store
            .set_fuel(COMPILED_FUEL)
            .map_err(|e| format!("Failed to set fuel: {}", e))?;

        // Use Linker for instantiation so we can provide WASI stubs
        let mut linker = Linker::new(&engine);
        Self::add_wasi_stubs(&mut linker)?;

        let instance = linker
            .instantiate(&mut store, &module)
            .map_err(|e| format!("Failed to instantiate module: {}", e))?;

        let memory = instance
            .get_memory(&mut store, "memory")
            .ok_or_else(|| "Module does not export 'memory'".to_string())?;

        let process_fn = instance
            .get_typed_func::<(i32, i32, i32, i32, f32), ()>(&mut store, "process")
            .map_err(|e| format!("Module does not export a valid 'process' function: {}", e))?;

        // Detect module-allocated buffers
        let get_input_ptr_fn = instance
            .get_typed_func::<(), i32>(&mut store, "get_input_ptr")
            .ok();
        let get_output_ptr_fn = instance
            .get_typed_func::<(), i32>(&mut store, "get_output_ptr")
            .ok();
        let get_params_ptr_fn = instance
            .get_typed_func::<(), i32>(&mut store, "get_params_ptr")
            .ok();

        let buffer_mode =
            if get_input_ptr_fn.is_some() && get_output_ptr_fn.is_some() {
                BufferMode::ModuleAllocated
            } else {
                BufferMode::FixedOffset
            };

        let fuel_per_callback = match buffer_mode {
            BufferMode::ModuleAllocated => COMPILED_FUEL,
            BufferMode::FixedOffset => DEFAULT_FUEL,
        };

        // Try get_param_metadata_json first (rich metadata), then fall back to get_param_names_json
        let (param_names, param_metadata) = Self::extract_params(
            &instance,
            &mut store,
            &memory,
        );

        // Determine how many params to write: metadata count, or 8 for backward compat
        let param_write_count = param_metadata
            .as_ref()
            .map(|m| m.len().min(PARAM_COUNT))
            .or_else(|| {
                if param_names.is_empty() {
                    None
                } else {
                    Some((*param_names.keys().max().unwrap_or(&0) as usize + 1).min(PARAM_COUNT))
                }
            })
            .unwrap_or(8); // Legacy default for old modules

        Ok(Self {
            store,
            memory,
            process_fn,
            get_input_ptr_fn,
            get_output_ptr_fn,
            get_params_ptr_fn,
            buffer_mode,
            input_offset: 0,
            output_offset: 0,
            params_offset: 0,
            channel_count: 0,
            max_frames: 0,
            fuel_per_callback,
            last_error: None,
            param_names,
            param_metadata,
            param_write_count,
        })
    }

    /// Extract parameter names and metadata from WASM module exports.
    fn extract_params(
        instance: &Instance,
        store: &mut Store<()>,
        memory: &Memory,
    ) -> (HashMap<u8, String>, Option<Vec<crate::params::ParamMetadata>>) {
        // Try get_param_metadata_json first (rich metadata)
        if let Ok(get_meta_fn) =
            instance.get_typed_func::<(), (i32, i32)>(&mut *store, "get_param_metadata_json")
        {
            let _ = store.set_fuel(COMPILED_FUEL);
            if let Ok((ptr, len)) = get_meta_fn.call(&mut *store, ()) {
                let data = memory.data(&*store);
                let start = ptr as usize;
                let end = start + len as usize;
                if end <= data.len() {
                    if let Ok(json_str) = std::str::from_utf8(&data[start..end]) {
                        if let Ok(metadata) =
                            serde_json::from_str::<Vec<crate::params::ParamMetadata>>(json_str)
                        {
                            if !metadata.is_empty() {
                                let names: HashMap<u8, String> = metadata
                                    .iter()
                                    .enumerate()
                                    .map(|(i, m)| (i as u8, m.name.clone()))
                                    .collect();
                                return (names, Some(metadata));
                            }
                        }
                    }
                }
            }
        }

        // Fall back to get_param_names_json
        let param_names = if let Ok(get_names_fn) =
            instance.get_typed_func::<(), (i32, i32)>(&mut *store, "get_param_names_json")
        {
            let _ = store.set_fuel(COMPILED_FUEL);
            match get_names_fn.call(&mut *store, ()) {
                Ok((ptr, len)) => {
                    let data = memory.data(&*store);
                    let start = ptr as usize;
                    let end = start + len as usize;
                    if end <= data.len() {
                        std::str::from_utf8(&data[start..end])
                            .ok()
                            .and_then(|s| {
                                serde_json::from_str::<HashMap<String, String>>(s).ok()
                            })
                            .map(|map| {
                                map.into_iter()
                                    .filter_map(|(k, v)| {
                                        let addr = k.parse::<u8>().ok()?;
                                        if (addr as usize) < PARAM_COUNT {
                                            Some((addr, v))
                                        } else {
                                            None
                                        }
                                    })
                                    .collect()
                            })
                            .unwrap_or_default()
                    } else {
                        HashMap::new()
                    }
                }
                Err(_) => HashMap::new(),
            }
        } else {
            HashMap::new()
        };

        (param_names, None)
    }

    /// Register minimal WASI preview1 stubs so compiled modules can instantiate.
    /// These stubs provide no real I/O — they return success with empty results.
    fn add_wasi_stubs(linker: &mut Linker<()>) -> Result<(), String> {
        let e = |err: Error| format!("Failed to register WASI stub: {}", err);

        // fd_write(fd, iovs_ptr, iovs_len, nwritten_ptr) -> errno
        linker
            .func_wrap(
                "wasi_snapshot_preview1",
                "fd_write",
                |mut caller: Caller<'_, ()>,
                 _fd: i32,
                 _iovs: i32,
                 _iovs_len: i32,
                 nwritten_ptr: i32|
                 -> i32 {
                    if let Some(memory) =
                        caller.get_export("memory").and_then(|e| e.into_memory())
                    {
                        let data = memory.data_mut(&mut caller);
                        let ptr = nwritten_ptr as usize;
                        if ptr + 4 <= data.len() {
                            data[ptr..ptr + 4].copy_from_slice(&0u32.to_le_bytes());
                        }
                    }
                    0
                },
            )
            .map_err(e)?;

        // fd_read(fd, iovs_ptr, iovs_len, nread_ptr) -> errno
        linker
            .func_wrap(
                "wasi_snapshot_preview1",
                "fd_read",
                |mut caller: Caller<'_, ()>,
                 _fd: i32,
                 _iovs: i32,
                 _iovs_len: i32,
                 nread_ptr: i32|
                 -> i32 {
                    if let Some(memory) =
                        caller.get_export("memory").and_then(|e| e.into_memory())
                    {
                        let data = memory.data_mut(&mut caller);
                        let ptr = nread_ptr as usize;
                        if ptr + 4 <= data.len() {
                            data[ptr..ptr + 4].copy_from_slice(&0u32.to_le_bytes());
                        }
                    }
                    0
                },
            )
            .map_err(e)?;

        // fd_close(fd) -> errno
        linker
            .func_wrap("wasi_snapshot_preview1", "fd_close", |_fd: i32| -> i32 { 0 })
            .map_err(e)?;

        // fd_seek(fd, offset, whence, new_offset_ptr) -> errno
        linker
            .func_wrap(
                "wasi_snapshot_preview1",
                "fd_seek",
                |_fd: i32, _offset: i64, _whence: i32, _new_offset_ptr: i32| -> i32 { 8 },
            )
            .map_err(e)?;

        // fd_prestat_get(fd, buf_ptr) -> errno
        linker
            .func_wrap(
                "wasi_snapshot_preview1",
                "fd_prestat_get",
                |_fd: i32, _buf: i32| -> i32 { 8 },
            )
            .map_err(e)?;

        // fd_prestat_dir_name(fd, path_ptr, path_len) -> errno
        linker
            .func_wrap(
                "wasi_snapshot_preview1",
                "fd_prestat_dir_name",
                |_fd: i32, _path: i32, _path_len: i32| -> i32 { 8 },
            )
            .map_err(e)?;

        // fd_fdstat_get(fd, buf_ptr) -> errno
        linker
            .func_wrap(
                "wasi_snapshot_preview1",
                "fd_fdstat_get",
                |_fd: i32, _buf: i32| -> i32 { 8 },
            )
            .map_err(e)?;

        // environ_sizes_get(count_ptr, size_ptr) -> errno
        linker
            .func_wrap(
                "wasi_snapshot_preview1",
                "environ_sizes_get",
                |mut caller: Caller<'_, ()>, count_ptr: i32, size_ptr: i32| -> i32 {
                    if let Some(memory) =
                        caller.get_export("memory").and_then(|e| e.into_memory())
                    {
                        let data = memory.data_mut(&mut caller);
                        let cp = count_ptr as usize;
                        let sp = size_ptr as usize;
                        if cp + 4 <= data.len() {
                            data[cp..cp + 4].copy_from_slice(&0u32.to_le_bytes());
                        }
                        if sp + 4 <= data.len() {
                            data[sp..sp + 4].copy_from_slice(&0u32.to_le_bytes());
                        }
                    }
                    0
                },
            )
            .map_err(e)?;

        // environ_get(environ_ptr, environ_buf_ptr) -> errno
        linker
            .func_wrap(
                "wasi_snapshot_preview1",
                "environ_get",
                |_environ: i32, _environ_buf: i32| -> i32 { 0 },
            )
            .map_err(e)?;

        // args_sizes_get(count_ptr, size_ptr) -> errno
        linker
            .func_wrap(
                "wasi_snapshot_preview1",
                "args_sizes_get",
                |mut caller: Caller<'_, ()>, count_ptr: i32, size_ptr: i32| -> i32 {
                    if let Some(memory) =
                        caller.get_export("memory").and_then(|e| e.into_memory())
                    {
                        let data = memory.data_mut(&mut caller);
                        let cp = count_ptr as usize;
                        let sp = size_ptr as usize;
                        if cp + 4 <= data.len() {
                            data[cp..cp + 4].copy_from_slice(&0u32.to_le_bytes());
                        }
                        if sp + 4 <= data.len() {
                            data[sp..sp + 4].copy_from_slice(&0u32.to_le_bytes());
                        }
                    }
                    0
                },
            )
            .map_err(e)?;

        // args_get(argv_ptr, argv_buf_ptr) -> errno
        linker
            .func_wrap(
                "wasi_snapshot_preview1",
                "args_get",
                |_argv: i32, _argv_buf: i32| -> i32 { 0 },
            )
            .map_err(e)?;

        // proc_exit(code) — should never return; if called, the module traps afterward
        linker
            .func_wrap("wasi_snapshot_preview1", "proc_exit", |_code: i32| {})
            .map_err(e)?;

        // clock_time_get(clock_id, precision, time_ptr) -> errno
        linker
            .func_wrap(
                "wasi_snapshot_preview1",
                "clock_time_get",
                |_clock_id: i32, _precision: i64, _time_ptr: i32| -> i32 { 0 },
            )
            .map_err(e)?;

        // random_get(buf_ptr, buf_len) -> errno
        linker
            .func_wrap(
                "wasi_snapshot_preview1",
                "random_get",
                |_buf: i32, _buf_len: i32| -> i32 { 0 },
            )
            .map_err(e)?;

        Ok(())
    }
}

impl Backend for WasmBackend {
    fn initialize(&mut self, channel_count: usize, _sample_rate: f64, max_frames: u32) {
        self.channel_count = channel_count;
        self.max_frames = max_frames;

        match self.buffer_mode {
            BufferMode::ModuleAllocated => {
                // Call module's getter functions to find buffer addresses
                if let (Some(get_in), Some(get_out)) =
                    (self.get_input_ptr_fn.clone(), self.get_output_ptr_fn.clone())
                {
                    // Need fuel for the getter calls
                    let _ = self.store.set_fuel(self.fuel_per_callback);
                    match (
                        get_in.call(&mut self.store, ()),
                        get_out.call(&mut self.store, ()),
                    ) {
                        (Ok(in_ptr), Ok(out_ptr)) => {
                            self.input_offset = in_ptr;
                            self.output_offset = out_ptr;
                        }
                        _ => {
                            self.last_error =
                                Some("Failed to call buffer getter functions".to_string());
                            self.input_offset = 0;
                            self.output_offset = 0;
                        }
                    }
                    // Optional: get params buffer address
                    if let Some(get_params) = self.get_params_ptr_fn.clone() {
                        if let Ok(ptr) = get_params.call(&mut self.store, ()) {
                            self.params_offset = ptr;
                        }
                    }
                }
            }
            BufferMode::FixedOffset => {
                // Calculate buffer sizes and use fixed offsets
                let bytes_per_buffer =
                    channel_count * max_frames as usize * std::mem::size_of::<f32>();
                let total_needed = MEMORY_BASE as usize + bytes_per_buffer * 2;

                // Grow memory if needed (WASM pages are 64KiB)
                let current_bytes = self.memory.data_size(&self.store);
                if total_needed > current_bytes {
                    let pages_needed = ((total_needed - current_bytes) + 65535) / 65536;
                    if let Err(e) = self.memory.grow(&mut self.store, pages_needed as u64) {
                        eprintln!("BearBone-WASM: Failed to grow memory: {}", e);
                        self.last_error = Some(format!("Failed to grow WASM memory: {}", e));
                        return;
                    }
                }

                self.input_offset = MEMORY_BASE;
                self.output_offset = MEMORY_BASE + bytes_per_buffer as i32;
            }
        }
    }

    fn deinitialize(&mut self) {
        // Nothing to free — WASM linear memory is managed by the engine.
        self.channel_count = 0;
        self.max_frames = 0;
        self.input_offset = 0;
        self.output_offset = 0;
        self.params_offset = 0;
    }

    unsafe fn process(
        &mut self,
        inputs: &[*const f32],
        outputs: &[*mut f32],
        channel_count: usize,
        frame_count: usize,
        sample_rate: f64,
        params: &[f32; PARAM_COUNT],
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

        // Write params into WASM memory if the module exports get_params_ptr.
        // Only write param_write_count entries to avoid overflowing the module's buffer.
        if self.params_offset != 0 {
            let params_byte_offset = self.params_offset as usize;
            let write_count = self.param_write_count.min(params.len());
            let params_end = params_byte_offset + write_count * 4;
            if params_end <= mem_data.len() {
                for i in 0..write_count {
                    let offset = params_byte_offset + i * 4;
                    mem_data[offset..offset + 4].copy_from_slice(&params[i].to_le_bytes());
                }
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

    fn param_names(&self) -> HashMap<u8, String> {
        self.param_names.clone()
    }

    fn param_metadata(&self) -> Option<&[crate::params::ParamMetadata]> {
        self.param_metadata.as_deref()
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
                &[0.0; PARAM_COUNT],
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
                &[0.0; PARAM_COUNT],
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
                &[0.0; PARAM_COUNT],
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
                &[0.0; PARAM_COUNT],
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
                &[0.0; PARAM_COUNT],
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
                    &[0.0; PARAM_COUNT],
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
                    &[0.0; PARAM_COUNT],
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

    // --- WASI stub tests ---

    /// WAT module that imports fd_write from WASI (simulates a compiled module).
    const WASI_FD_WRITE_WAT: &str = r#"
        (module
          (import "wasi_snapshot_preview1" "fd_write"
            (func $fd_write (param i32 i32 i32 i32) (result i32)))
          (memory (export "memory") 1)
          (func (export "process")
            (param $in i32) (param $out i32) (param $ch i32) (param $frames i32) (param $sr f32)
            ;; Just passthrough — the fd_write import exists but is not called
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

    /// WAT module that imports and calls environ_sizes_get.
    const WASI_ENVIRON_WAT: &str = r#"
        (module
          (import "wasi_snapshot_preview1" "environ_sizes_get"
            (func $environ_sizes_get (param i32 i32) (result i32)))
          (memory (export "memory") 1)
          (func (export "process")
            (param $in i32) (param $out i32) (param $ch i32) (param $frames i32) (param $sr f32)
            (local $i i32)
            (local $total i32)
            ;; Call environ_sizes_get to verify the stub works
            ;; Write count to offset 0, size to offset 4
            (drop (call $environ_sizes_get (i32.const 0) (i32.const 4)))
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

    /// WAT module with buffer getter exports (simulates a compiled Rust module).
    /// Uses data segment at offset 256 for input buffer and 512 for output buffer.
    const BUFFER_GETTERS_WAT: &str = r#"
        (module
          (memory (export "memory") 1)

          ;; Buffer getter exports — return addresses of pre-allocated buffers
          (func (export "get_input_ptr") (result i32)
            (i32.const 256)
          )
          (func (export "get_output_ptr") (result i32)
            (i32.const 512)
          )

          ;; 0.5x gain using the module's own buffer addresses
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

    #[test]
    fn test_wasm_wasi_module_loads() {
        let wasm = wat_to_wasm(WASI_FD_WRITE_WAT);
        let backend = WasmBackend::load(&wasm);
        assert!(
            backend.is_ok(),
            "Module with WASI imports should load via stubs: {:?}",
            backend.err()
        );
    }

    #[test]
    fn test_wasm_wasi_module_processes() {
        let wasm = wat_to_wasm(WASI_FD_WRITE_WAT);
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
                &[0.0; PARAM_COUNT],
            )
        };
        assert!(ok, "WASI module should process audio");
        assert_eq!(output, [0.1, 0.2, 0.3, 0.4]);
    }

    #[test]
    fn test_wasm_wasi_environ_stubs() {
        let wasm = wat_to_wasm(WASI_ENVIRON_WAT);
        let mut backend = WasmBackend::load(&wasm).unwrap();
        backend.initialize(1, 44100.0, 1024);

        let input: [f32; 4] = [1.0, 2.0, 3.0, 4.0];
        let mut output: [f32; 4] = [0.0; 4];

        let ok = unsafe {
            backend.process(
                &[input.as_ptr()],
                &[output.as_mut_ptr()],
                1,
                4,
                44100.0,
                &[0.0; PARAM_COUNT],
            )
        };
        assert!(ok, "Module calling environ_sizes_get should work");
        assert_eq!(output, [1.0, 2.0, 3.0, 4.0]);
    }

    #[test]
    fn test_wasm_buffer_getters_detected() {
        let wasm = wat_to_wasm(BUFFER_GETTERS_WAT);
        let backend = WasmBackend::load(&wasm).unwrap();
        assert!(
            backend.get_input_ptr_fn.is_some(),
            "Should detect get_input_ptr export"
        );
        assert!(
            backend.get_output_ptr_fn.is_some(),
            "Should detect get_output_ptr export"
        );
        assert!(
            matches!(backend.buffer_mode, BufferMode::ModuleAllocated),
            "Should use ModuleAllocated mode"
        );
    }

    #[test]
    fn test_wasm_buffer_getters_not_detected_for_simple_modules() {
        let wasm = wat_to_wasm(GAIN_HALF_WAT);
        let backend = WasmBackend::load(&wasm).unwrap();
        assert!(
            backend.get_input_ptr_fn.is_none(),
            "Simple module should not have getters"
        );
        assert!(
            matches!(backend.buffer_mode, BufferMode::FixedOffset),
            "Should use FixedOffset mode"
        );
    }

    #[test]
    fn test_wasm_buffer_getters_process_audio() {
        let wasm = wat_to_wasm(BUFFER_GETTERS_WAT);
        let mut backend = WasmBackend::load(&wasm).unwrap();
        backend.initialize(1, 44100.0, 1024);

        // Verify offsets were set from getter functions (256 and 512)
        assert_eq!(backend.input_offset, 256, "input should be at getter address");
        assert_eq!(backend.output_offset, 512, "output should be at getter address");

        let input: [f32; 4] = [1.0, 0.5, -1.0, 0.0];
        let mut output: [f32; 4] = [0.0; 4];

        let ok = unsafe {
            backend.process(
                &[input.as_ptr()],
                &[output.as_mut_ptr()],
                1,
                4,
                44100.0,
                &[0.0; PARAM_COUNT],
            )
        };
        assert!(ok, "Module with buffer getters should process audio");
        assert_eq!(output, [0.5, 0.25, -0.5, 0.0]);
    }

    #[test]
    fn test_wasm_no_param_names_returns_empty() {
        let wasm = wat_to_wasm(GAIN_HALF_WAT);
        let backend = WasmBackend::load(&wasm).unwrap();
        assert!(backend.param_names().is_empty());
    }

    /// Helper: build WAT bytes for a JSON data segment in WASM memory.
    fn json_to_wat_hex(json: &str) -> String {
        json.bytes().map(|b| format!("\\{:02x}", b)).collect()
    }

    #[test]
    fn test_wasm_param_names_from_export() {
        let json = r#"{"0":"Gain","1":"Mix"}"#;
        let hex = json_to_wat_hex(json);
        let wat = format!(
            r#"
            (module
              (memory (export "memory") 1)
              (data (i32.const 1024) "{hex}")
              (func (export "process")
                (param $in i32) (param $out i32) (param $ch i32) (param $frames i32) (param $sr f32)
              )
              (func (export "get_param_names_json") (result i32 i32)
                (i32.const 1024)
                (i32.const {len})
              )
            )
            "#,
            hex = hex,
            len = json.len(),
        );
        let wasm = wat_to_wasm(&wat);
        let backend = WasmBackend::load(&wasm).unwrap();
        let names = backend.param_names();
        assert_eq!(names.len(), 2);
        assert_eq!(names[&0], "Gain");
        assert_eq!(names[&1], "Mix");
    }

    #[test]
    fn test_wasm_param_names_invalid_address_filtered() {
        let json = r#"{"0":"Gain","99":"Invalid"}"#;
        let hex = json_to_wat_hex(json);
        let wat = format!(
            r#"
            (module
              (memory (export "memory") 1)
              (data (i32.const 1024) "{hex}")
              (func (export "process")
                (param $in i32) (param $out i32) (param $ch i32) (param $frames i32) (param $sr f32)
              )
              (func (export "get_param_names_json") (result i32 i32)
                (i32.const 1024)
                (i32.const {len})
              )
            )
            "#,
            hex = hex,
            len = json.len(),
        );
        let wasm = wat_to_wasm(&wat);
        let backend = WasmBackend::load(&wasm).unwrap();
        let names = backend.param_names();
        assert_eq!(names.len(), 1);
        assert_eq!(names[&0], "Gain");
    }

    #[test]
    fn test_wasm_compiled_module_gets_higher_fuel() {
        let wasm = wat_to_wasm(BUFFER_GETTERS_WAT);
        let backend = WasmBackend::load(&wasm).unwrap();
        assert_eq!(
            backend.fuel_per_callback, COMPILED_FUEL,
            "Compiled modules should get higher fuel budget"
        );

        let wasm = wat_to_wasm(GAIN_HALF_WAT);
        let backend = WasmBackend::load(&wasm).unwrap();
        assert_eq!(
            backend.fuel_per_callback, DEFAULT_FUEL,
            "Simple modules should get default fuel budget"
        );
    }
}
