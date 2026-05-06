use crate::backend::{Backend, SidechainInput};
use crate::kernel::TransportState;
use crate::params::PARAM_COUNT;
use std::collections::HashMap;
use wasmtime::*;

// ---------------------------------------------------------------------------
// Accelerate framework FFI (Apple vDSP / vecLib)
// ---------------------------------------------------------------------------

#[cfg(target_os = "macos")]
extern "C" {
    /// C = A * B where A is m×k, B is k×n, C is m×n. Stride params are element strides.
    fn vDSP_mmul(
        a: *const f32, a_stride: i32,
        b: *const f32, b_stride: i32,
        c: *mut f32, c_stride: i32,
        m: u32, k: u32, n: u32,
    );
    /// C[i] = A[i] + B[i]
    fn vDSP_vadd(
        a: *const f32, a_stride: i32,
        b: *const f32, b_stride: i32,
        c: *mut f32, c_stride: i32,
        n: u32,
    );
    /// C[i] = A[i] * B[i]
    fn vDSP_vmul(
        a: *const f32, a_stride: i32,
        b: *const f32, b_stride: i32,
        c: *mut f32, c_stride: i32,
        n: u32,
    );
    /// C[i] = A[i] + *B (add scalar)
    fn vDSP_vsadd(
        a: *const f32, a_stride: i32,
        b: *const f32,
        c: *mut f32, c_stride: i32,
        n: u32,
    );
    /// y[i] = tanh(x[i])
    fn vvtanhf(y: *mut f32, x: *const f32, n: *const i32);
    /// y[i] = exp(x[i])
    fn vvexpf(y: *mut f32, x: *const f32, n: *const i32);
    /// C[i] = -A[i]
    fn vDSP_vneg(
        a: *const f32, a_stride: i32,
        c: *mut f32, c_stride: i32,
        n: u32,
    );
    /// C[i] = *A / B[i]
    fn vDSP_svdiv(
        a: *const f32,
        b: *const f32, b_stride: i32,
        c: *mut f32, c_stride: i32,
        n: u32,
    );
    /// BLAS general matrix multiply: C = alpha*A*B + beta*C
    /// order: 101=RowMajor, transA/transB: 111=NoTrans
    fn cblas_sgemm(
        order: i32, trans_a: i32, trans_b: i32,
        m: i32, n: i32, k: i32,
        alpha: f32, a: *const f32, lda: i32,
        b: *const f32, ldb: i32,
        beta: f32, c: *mut f32, ldc: i32,
    );
}

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
///   `(input_ptr: i32, output_ptr: i32, channel_count: i32, frame_count: i32, sample_rate: f32) -> ()`
///
/// Memory layout at input_ptr / output_ptr:
///   Channels laid out sequentially, each `frame_count` floats.
///   `[ch0_f0, ch0_f1, ..., ch1_f0, ch1_f1, ...]`
///
/// Compiled modules (Rust/C targeting wasm32-wasip1) should export `get_input_ptr()` and
/// `get_output_ptr()` functions that return the addresses of pre-allocated static buffers.
/// This avoids memory layout conflicts with the compiler's stack/heap.
/// Host-side state accessible from WASM import functions via `Caller<'_, HostState>`.
pub struct HostState {
    /// Native NAM models for host-side inference (avoids running NAM inside WASM sandbox).
    /// One slot per `nam!()` / `nams!()` declaration in the WASM module, indexed by
    /// declaration order. Empty when no NAM is declared. A `None` entry means the
    /// host failed to inject that slot (e.g. tone not downloaded) — calls to
    /// `__conjuredsp_nam_process_slot` for an empty slot return 0.
    pub nam_models: Vec<Option<conjuredsp::NamModel>>,
}

pub struct WasmBackend {
    store: Store<HostState>,
    memory: Memory,
    process_fn: TypedFunc<(i32, i32, i32, i32, f32), ()>,
    get_input_ptr_fn: Option<TypedFunc<(), i32>>,
    get_output_ptr_fn: Option<TypedFunc<(), i32>>,
    get_params_ptr_fn: Option<TypedFunc<(), i32>>,
    get_transport_ptr_fn: Option<TypedFunc<(), i32>>,
    buffer_mode: BufferMode,
    input_offset: i32,
    output_offset: i32,
    params_offset: i32,
    transport_offset: i32,
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
    /// Script-declared algorithmic latency in samples (from `get_latency_samples` export).
    latency_samples: u32,
    /// NAM model paths embedded in the WASM binary via `get_nam_manifest_ptr`/`get_nam_manifest_len`.
    /// One entry per slot, in declaration order. Empty when the module declares no NAM models.
    nam_paths: Vec<String>,
    /// Script-declared telemetry slot metadata (from `get_telemetry_metadata_ptr/_len`).
    /// `None` when the script didn't call `telemetry!()` — kernel skips reads.
    telemetry_metadata: Option<Vec<crate::params::TelemetryMetadata>>,
    /// Cached offset of the script's TELEMETRY_BUF in WASM linear memory
    /// (via `get_telemetry_buf_ptr`). Captured once at load time so each
    /// `read_telemetry` call is just a slice read, no exported-function
    /// invocation. Always set when `setup!()` was used (the buffer is
    /// allocated regardless of whether telemetry slots are declared);
    /// only meaningful when `telemetry_metadata` is also `Some`.
    telemetry_buf_offset: Option<i32>,
    /// Cached per-slot base offsets of the macro-emitted vector
    /// telemetry buffers (via `get_telemetry_vec_ptr(slot)`), one entry
    /// per declared metadata slot. Scalar slots and slots whose export
    /// returned 0/null get `None`. Captured once at load time so the
    /// audio-thread `read_telemetry_vec` path is a pure slice read with
    /// no wasmtime function-call overhead.
    telemetry_vec_offsets: Vec<Option<i32>>,
    /// Cached offset of the script's SIDECHAIN_BUF in WASM linear
    /// memory (via `get_sidechain_ptr`). `None` for legacy modules
    /// that don't declare sidechain — the host writes nothing in that
    /// case, costing zero on the hot path.
    sidechain_buf_offset: Option<i32>,
    /// Cached offset of `SIDECHAIN_STATE: [i32; 2]` (channel_count,
    /// connected) — written before each `process()` call so the script
    /// knows whether to follow the sidechain or fall back to internal
    /// detection. `None` when the export is missing.
    sidechain_state_offset: Option<i32>,
    /// Maximum sidechain channels the script's buffer can hold, derived
    /// from `get_sidechain_buf_len()` (bytes / 4 / max_frames). Capped
    /// at 2 in practice; used to clip when the host pulls more channels
    /// than the script allocated.
    sidechain_max_channels: usize,
}

/// Base offset in WASM linear memory to avoid the null page.
const MEMORY_BASE: i32 = 1024;

/// Default fuel budget per audio callback (~1M instructions) for hand-written WAT.
const DEFAULT_FUEL: u64 = 1_000_000;

/// Higher fuel budget for compiled modules (Rust/C via wasm32-wasip1).
/// Compiled code includes musl overhead, bounds checking, etc.
const COMPILED_FUEL: u64 = 10_000_000;

/// Much higher fuel budget for NAM-active WASM modules.
/// WaveNet standard (16ch, 4 arrays × 10 layers) needs ~230M WASM instructions per buffer;
/// WaveNet large (32ch) needs ~460M. Use 2B to give headroom for all current model sizes.
const NAM_FUEL: u64 = 2_000_000_000;

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

        let mut store = Store::new(&engine, HostState { nam_models: Vec::new() });
        store
            .set_fuel(COMPILED_FUEL)
            .map_err(|e| format!("Failed to set fuel: {}", e))?;

        // Use Linker for instantiation so we can provide WASI stubs and Accelerate imports
        let mut linker = Linker::new(&engine);
        Self::add_wasi_stubs(&mut linker)?;
        Self::add_conjuredsp_imports(&mut linker)?;
        Self::add_nam_import(&mut linker)?;

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
        let get_transport_ptr_fn = instance
            .get_typed_func::<(), i32>(&mut store, "get_transport_ptr")
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

        // Try get_param_metadata_ptr/len first (rich metadata), then fall back to get_param_names_json
        let (param_names, param_metadata) = Self::extract_params(
            &instance,
            &mut store,
            &memory,
        );

        // Optional telemetry metadata + buffer offset. Both come from the
        // conjuredsp-rs author crate's `setup!()` + `telemetry!()` macros.
        // Missing exports = no telemetry (legacy modules + scripts that
        // didn't opt in). The buffer offset only matters when metadata
        // is also present.
        let telemetry_metadata = Self::extract_telemetry(&instance, &mut store, &memory);
        let telemetry_buf_offset = instance
            .get_typed_func::<(), i32>(&mut store, "get_telemetry_buf_ptr")
            .ok()
            .and_then(|f| {
                let _ = store.set_fuel(COMPILED_FUEL);
                f.call(&mut store, ()).ok()
            });
        // Resolve per-slot vector base pointers (one call per declared slot
        // at load time; runtime reads are pure memory slices). The export
        // is named `get_telemetry_vec_ptr(slot: i32) -> i32` and returns 0
        // for non-vector / out-of-range slots.
        let telemetry_vec_offsets: Vec<Option<i32>> = match (&telemetry_metadata,
            instance.get_typed_func::<i32, i32>(&mut store, "get_telemetry_vec_ptr").ok())
        {
            (Some(meta), Some(f)) => meta
                .iter()
                .enumerate()
                .map(|(i, spec)| {
                    if !spec.is_vector() {
                        return None;
                    }
                    let _ = store.set_fuel(COMPILED_FUEL);
                    match f.call(&mut store, i as i32) {
                        Ok(0) => None,
                        Ok(p) => Some(p),
                        Err(_) => None,
                    }
                })
                .collect(),
            _ => Vec::new(),
        };

        // Probe for optional sidechain exports. Modules that don't
        // declare `setup!()` with the sidechain block (or pre-sidechain
        // setup macros) won't have these — we leave the offsets at None
        // and the host writes nothing to sidechain memory at runtime.
        let sidechain_buf_offset = instance
            .get_typed_func::<(), i32>(&mut store, "get_sidechain_ptr")
            .ok()
            .and_then(|f| {
                let _ = store.set_fuel(COMPILED_FUEL);
                f.call(&mut store, ()).ok()
            });
        let sidechain_state_offset = instance
            .get_typed_func::<(), i32>(&mut store, "get_sidechain_state_ptr")
            .ok()
            .and_then(|f| {
                let _ = store.set_fuel(COMPILED_FUEL);
                f.call(&mut store, ()).ok()
            });
        let sidechain_buf_len = instance
            .get_typed_func::<(), i32>(&mut store, "get_sidechain_buf_len")
            .ok()
            .and_then(|f| {
                let _ = store.set_fuel(COMPILED_FUEL);
                f.call(&mut store, ()).ok()
            })
            .unwrap_or(0);

        // Probe for optional get_latency_samples() export
        let latency_samples = instance
            .get_typed_func::<(), i32>(&mut store, "get_latency_samples")
            .ok()
            .and_then(|f| {
                let _ = store.set_fuel(COMPILED_FUEL);
                f.call(&mut store, ()).ok()
            })
            .map(|v| if v < 0 { 0 } else { v as u32 })
            .unwrap_or(0);

        // Read NAM manifest if available — newline-separated paths, one per slot
        // in declaration order. Empty trailing entries are dropped.
        let nam_paths: Vec<String> = {
            let get_ptr = instance
                .get_typed_func::<(), i32>(&mut store, "get_nam_manifest_ptr")
                .ok();
            let get_len = instance
                .get_typed_func::<(), i32>(&mut store, "get_nam_manifest_len")
                .ok();
            if let (Some(ptr_fn), Some(len_fn)) = (get_ptr, get_len) {
                let _ = store.set_fuel(COMPILED_FUEL);
                let ptr = ptr_fn.call(&mut store, ()).ok();
                let _ = store.set_fuel(COMPILED_FUEL);
                let len = len_fn.call(&mut store, ()).ok();
                if let (Some(p), Some(l)) = (ptr, len) {
                    let data = memory.data(&store);
                    let start = p as usize;
                    let end = start + l as usize;
                    if end <= data.len() {
                        std::str::from_utf8(&data[start..end])
                            .map(|s| {
                                s.split('\n')
                                    .filter(|line| !line.is_empty())
                                    .map(String::from)
                                    .collect()
                            })
                            .unwrap_or_default()
                    } else {
                        Vec::new()
                    }
                } else {
                    Vec::new()
                }
            } else {
                Vec::new()
            }
        };

        // Pre-size the model slots so `inject_nam_model_slot` can index directly
        // and out-of-range calls from WASM are detected as empty slots.
        if !nam_paths.is_empty() {
            let count = nam_paths.len();
            let mut models = Vec::with_capacity(count);
            for _ in 0..count {
                models.push(None);
            }
            store.data_mut().nam_models = models;
        }

        let has_nam = !nam_paths.is_empty();

        // Use higher fuel budget for NAM-active modules (host import call still
        // needs fuel for WASM-side copy loops around the import).
        let fuel_per_callback = if has_nam {
            NAM_FUEL
        } else {
            fuel_per_callback
        };

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

        // Compute sidechain channel capacity from declared buffer length.
        // The macro emits SIDECHAIN_BUF: [f32; MAX_CH * MAX_FR]; bytes / 4
        // / MAX_FRAMES gives MAX_CH. Falls back to 0 when sidechain isn't
        // declared so the host write loop becomes a no-op.
        let sidechain_max_channels = if sidechain_buf_len > 0 {
            (sidechain_buf_len as usize / 4) / conjuredsp::MAX_FRAMES
        } else {
            0
        };

        Ok(Self {
            store,
            memory,
            process_fn,
            get_input_ptr_fn,
            get_output_ptr_fn,
            get_params_ptr_fn,
            get_transport_ptr_fn,
            buffer_mode,
            input_offset: 0,
            output_offset: 0,
            params_offset: 0,
            transport_offset: 0,
            channel_count: 0,
            max_frames: 0,
            fuel_per_callback,
            last_error: None,
            param_names,
            param_metadata,
            param_write_count,
            latency_samples,
            nam_paths,
            telemetry_metadata,
            telemetry_buf_offset,
            telemetry_vec_offsets,
            sidechain_buf_offset,
            sidechain_state_offset,
            sidechain_max_channels,
        })
    }

    /// Extract telemetry slot metadata from `get_telemetry_metadata_ptr/_len`
    /// exports. Returns `None` when the script didn't opt in (the macro
    /// pair from `telemetry!()` wasn't invoked) — kernel skips reads in
    /// that case. Schema mirrors the params extractor: JSON
    /// `[{name, unit}, …]` decoded into `Vec<TelemetryMetadata>`.
    fn extract_telemetry(
        instance: &Instance,
        store: &mut Store<HostState>,
        memory: &Memory,
    ) -> Option<Vec<crate::params::TelemetryMetadata>> {
        let get_ptr_fn = instance
            .get_typed_func::<(), i32>(&mut *store, "get_telemetry_metadata_ptr")
            .ok()?;
        let get_len_fn = instance
            .get_typed_func::<(), i32>(&mut *store, "get_telemetry_metadata_len")
            .ok()?;

        let _ = store.set_fuel(COMPILED_FUEL);
        let ptr = get_ptr_fn.call(&mut *store, ()).ok()?;
        let _ = store.set_fuel(COMPILED_FUEL);
        let len = get_len_fn.call(&mut *store, ()).ok()?;

        let data = memory.data(&*store);
        let start = ptr as usize;
        let end = start.checked_add(len as usize)?;
        if end > data.len() {
            return None;
        }
        let json_str = std::str::from_utf8(&data[start..end]).ok()?;
        let metadata: Vec<crate::params::TelemetryMetadata> =
            serde_json::from_str(json_str).ok()?;
        if metadata.is_empty() {
            None
        } else {
            Some(metadata)
        }
    }

    /// Extract parameter names and metadata from WASM module exports.
    fn extract_params(
        instance: &Instance,
        store: &mut Store<HostState>,
        memory: &Memory,
    ) -> (HashMap<u8, String>, Option<Vec<crate::params::ParamMetadata>>) {
        // Try get_param_metadata_ptr/len first (rich metadata).
        // Uses two separate functions to avoid WASM multi-value return ABI issues
        // (Rust's extern "C" on wasm32 doesn't reliably produce multi-value returns).
        if let (Ok(get_ptr_fn), Ok(get_len_fn)) = (
            instance.get_typed_func::<(), i32>(&mut *store, "get_param_metadata_ptr"),
            instance.get_typed_func::<(), i32>(&mut *store, "get_param_metadata_len"),
        ) {
            let _ = store.set_fuel(COMPILED_FUEL);
            let ptr_result = get_ptr_fn.call(&mut *store, ());
            let _ = store.set_fuel(COMPILED_FUEL);
            let len_result = get_len_fn.call(&mut *store, ());
            if let (Ok(ptr), Ok(len)) = (ptr_result, len_result) {
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
    fn add_wasi_stubs(linker: &mut Linker<HostState>) -> Result<(), String> {
        let e = |err: Error| format!("Failed to register WASI stub: {}", err);

        // fd_write(fd, iovs_ptr, iovs_len, nwritten_ptr) -> errno
        linker
            .func_wrap(
                "wasi_snapshot_preview1",
                "fd_write",
                |mut caller: Caller<'_, HostState>,
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
                |mut caller: Caller<'_, HostState>,
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
                |mut caller: Caller<'_, HostState>, count_ptr: i32, size_ptr: i32| -> i32 {
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
                |mut caller: Caller<'_, HostState>, count_ptr: i32, size_ptr: i32| -> i32 {
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

    /// Register `__conjuredsp_nam_process_slot` host import for native NAM inference.
    ///
    /// When a WASM module calls this import, the host reads audio from WASM memory,
    /// runs `NamModel::process_buffer()` natively on the model in `slot`, and writes
    /// results back. Returns 0 if the slot index is out of range or the slot has no
    /// injected model (e.g. the user's tone wasn't downloaded).
    fn add_nam_import(linker: &mut Linker<HostState>) -> Result<(), String> {
        linker
            .func_wrap(
                "env",
                "__conjuredsp_nam_process_slot",
                |mut caller: Caller<'_, HostState>,
                 slot: u32,
                 input_ptr: i32, output_ptr: i32, frames: i32, channel: i32| -> i32 {
                    let memory = match caller.get_export("memory").and_then(|e| e.into_memory()) {
                        Some(m) => m,
                        None => return 0,
                    };

                    let n = frames as usize;
                    let in_off = input_ptr as usize;
                    let out_off = output_ptr as usize;

                    // Read input as zero-copy f32 slice from WASM memory.
                    // Safe: both WASM and ARM64 are little-endian, static f32 arrays are 4-byte aligned.
                    let data = memory.data(&caller);
                    if in_off + n * 4 > data.len() || out_off + n * 4 > data.len() {
                        return 0;
                    }
                    let input_slice = unsafe {
                        std::slice::from_raw_parts(data.as_ptr().add(in_off) as *const f32, n)
                    };

                    // Copy input because caller.data_mut() below invalidates the data slice.
                    let input_copy: Vec<f32> = input_slice.to_vec();

                    // Take model out of HostState slot so we can borrow caller for memory access.
                    // Bounds-check the slot, and treat an empty slot as "no model" (returns 0).
                    let slot_idx = slot as usize;
                    let mut model = {
                        let models = &mut caller.data_mut().nam_models;
                        if slot_idx >= models.len() {
                            return 0;
                        }
                        match models[slot_idx].take() {
                            Some(m) => m,
                            None => return 0,
                        }
                    };

                    // Zero-copy output: write directly into WASM memory.
                    let data = memory.data_mut(&mut caller);
                    let output_slice = unsafe {
                        std::slice::from_raw_parts_mut(data.as_mut_ptr().add(out_off) as *mut f32, n)
                    };
                    model.process_buffer(&input_copy, output_slice, channel as usize);

                    // Put model back.
                    caller.data_mut().nam_models[slot_idx] = Some(model);
                    1
                },
            )
            .map_err(|e| format!("Failed to register NAM import: {}", e))?;

        Ok(())
    }

    /// Register Accelerate-backed host imports under the "conjuredsp" module.
    ///
    /// These provide hardware-accelerated math to WASM modules that declare
    /// `#[link(wasm_import_module = "conjuredsp")]` imports.  Modules that
    /// don't import these functions are unaffected.
    #[cfg(target_os = "macos")]
    fn add_conjuredsp_imports(linker: &mut Linker<HostState>) -> Result<(), String> {
        let e = |err: Error| format!("Failed to register conjuredsp import: {}", err);

        // matmul(a_ptr, b_ptr, out_ptr, m, k, n)
        linker
            .func_wrap(
                "conjuredsp",
                "host_matmul",
                |mut caller: Caller<'_, HostState>,
                 a_ptr: i32, b_ptr: i32, out_ptr: i32,
                 m: i32, k: i32, n: i32| {
                    if let Some(memory) = caller.get_export("memory").and_then(|e| e.into_memory()) {
                        let data = memory.data_mut(&mut caller);
                        let a_off = a_ptr as usize;
                        let b_off = b_ptr as usize;
                        let out_off = out_ptr as usize;
                        let a_bytes = (m as usize) * (k as usize) * 4;
                        let b_bytes = (k as usize) * (n as usize) * 4;
                        let out_bytes = (m as usize) * (n as usize) * 4;
                        if a_off + a_bytes > data.len()
                            || b_off + b_bytes > data.len()
                            || out_off + out_bytes > data.len()
                        {
                            return;
                        }
                        let base = data.as_mut_ptr();
                        unsafe {
                            // vDSP_mmul(A, 1, B, 1, C, 1, M, N, P)
                            // A is M×P, B is P×N, C is M×N
                            // Our contract: a is m×k, b is k×n, out is m×n
                            // So: M=m, P=k, N=n
                            vDSP_mmul(
                                base.add(a_off) as *const f32, 1,
                                base.add(b_off) as *const f32, 1,
                                base.add(out_off) as *mut f32, 1,
                                m as u32, n as u32, k as u32,
                            );
                        }
                    }
                },
            )
            .map_err(e)?;

        // matmul_acc(a_ptr, b_ptr, c_ptr, m, k, n) — C += A @ B via cblas_sgemm(beta=1)
        linker
            .func_wrap(
                "conjuredsp",
                "host_matmul_acc",
                |mut caller: Caller<'_, HostState>,
                 a_ptr: i32, b_ptr: i32, c_ptr: i32,
                 m: i32, k: i32, n: i32| {
                    if let Some(memory) = caller.get_export("memory").and_then(|e| e.into_memory()) {
                        let data = memory.data_mut(&mut caller);
                        let a_off = a_ptr as usize;
                        let b_off = b_ptr as usize;
                        let c_off = c_ptr as usize;
                        let a_bytes = (m as usize) * (k as usize) * 4;
                        let b_bytes = (k as usize) * (n as usize) * 4;
                        let c_bytes = (m as usize) * (n as usize) * 4;
                        if a_off + a_bytes > data.len()
                            || b_off + b_bytes > data.len()
                            || c_off + c_bytes > data.len()
                        {
                            return;
                        }
                        let base = data.as_mut_ptr();
                        unsafe {
                            // CblasRowMajor=101, CblasNoTrans=111
                            // C = 1.0 * A @ B + 1.0 * C  →  C += A @ B
                            cblas_sgemm(
                                101, 111, 111,
                                m, n, k,
                                1.0_f32,
                                base.add(a_off) as *const f32, k,
                                base.add(b_off) as *const f32, n,
                                1.0_f32,
                                base.add(c_off) as *mut f32, n,
                            );
                        }
                    }
                },
            )
            .map_err(e)?;

        // vec_add(a_ptr, b_ptr, out_ptr, len)
        linker
            .func_wrap(
                "conjuredsp",
                "host_vec_add",
                |mut caller: Caller<'_, HostState>,
                 a_ptr: i32, b_ptr: i32, out_ptr: i32, len: i32| {
                    if let Some(memory) = caller.get_export("memory").and_then(|e| e.into_memory()) {
                        let data = memory.data_mut(&mut caller);
                        let bytes = (len as usize) * 4;
                        let (a, b, o) = (a_ptr as usize, b_ptr as usize, out_ptr as usize);
                        if a + bytes > data.len() || b + bytes > data.len() || o + bytes > data.len() {
                            return;
                        }
                        let base = data.as_mut_ptr();
                        unsafe {
                            vDSP_vadd(
                                base.add(a) as *const f32, 1,
                                base.add(b) as *const f32, 1,
                                base.add(o) as *mut f32, 1,
                                len as u32,
                            );
                        }
                    }
                },
            )
            .map_err(e)?;

        // vec_mul(a_ptr, b_ptr, out_ptr, len)
        linker
            .func_wrap(
                "conjuredsp",
                "host_vec_mul",
                |mut caller: Caller<'_, HostState>,
                 a_ptr: i32, b_ptr: i32, out_ptr: i32, len: i32| {
                    if let Some(memory) = caller.get_export("memory").and_then(|e| e.into_memory()) {
                        let data = memory.data_mut(&mut caller);
                        let bytes = (len as usize) * 4;
                        let (a, b, o) = (a_ptr as usize, b_ptr as usize, out_ptr as usize);
                        if a + bytes > data.len() || b + bytes > data.len() || o + bytes > data.len() {
                            return;
                        }
                        let base = data.as_mut_ptr();
                        unsafe {
                            vDSP_vmul(
                                base.add(a) as *const f32, 1,
                                base.add(b) as *const f32, 1,
                                base.add(o) as *mut f32, 1,
                                len as u32,
                            );
                        }
                    }
                },
            )
            .map_err(e)?;

        // vec_tanh(inp_ptr, out_ptr, len)
        linker
            .func_wrap(
                "conjuredsp",
                "host_vec_tanh",
                |mut caller: Caller<'_, HostState>,
                 inp_ptr: i32, out_ptr: i32, len: i32| {
                    if let Some(memory) = caller.get_export("memory").and_then(|e| e.into_memory()) {
                        let data = memory.data_mut(&mut caller);
                        let bytes = (len as usize) * 4;
                        let (i, o) = (inp_ptr as usize, out_ptr as usize);
                        if i + bytes > data.len() || o + bytes > data.len() {
                            return;
                        }
                        let base = data.as_mut_ptr();
                        let n = len;
                        unsafe {
                            vvtanhf(
                                base.add(o) as *mut f32,
                                base.add(i) as *const f32,
                                &n,
                            );
                        }
                    }
                },
            )
            .map_err(e)?;

        // vec_sigmoid(inp_ptr, out_ptr, len)
        // sigmoid(x) = 1 / (1 + exp(-x))
        // Implemented as: negate → exp → add 1 → reciprocal divide
        linker
            .func_wrap(
                "conjuredsp",
                "host_vec_sigmoid",
                |mut caller: Caller<'_, HostState>,
                 inp_ptr: i32, out_ptr: i32, len: i32| {
                    if let Some(memory) = caller.get_export("memory").and_then(|e| e.into_memory()) {
                        let data = memory.data_mut(&mut caller);
                        let bytes = (len as usize) * 4;
                        let (i_off, o_off) = (inp_ptr as usize, out_ptr as usize);
                        if i_off + bytes > data.len() || o_off + bytes > data.len() {
                            return;
                        }
                        // Use a host-side temp buffer to avoid aliasing issues
                        let count = len as usize;
                        let mut temp = vec![0.0f32; count];
                        let base = data.as_mut_ptr();
                        let n = len;
                        let one = 1.0f32;
                        unsafe {
                            let inp = base.add(i_off) as *const f32;
                            let out = base.add(o_off) as *mut f32;
                            // temp = -inp
                            vDSP_vneg(inp, 1, temp.as_mut_ptr(), 1, count as u32);
                            // Clamp to [-88, 88] to avoid overflow
                            for v in temp.iter_mut() {
                                *v = v.clamp(-88.0, 88.0);
                            }
                            // temp = exp(-inp)
                            vvexpf(temp.as_mut_ptr(), temp.as_ptr(), &n);
                            // temp = 1 + exp(-inp)
                            vDSP_vsadd(temp.as_ptr(), 1, &one, temp.as_mut_ptr(), 1, count as u32);
                            // out = 1 / (1 + exp(-inp))
                            vDSP_svdiv(&one, temp.as_ptr(), 1, out, 1, count as u32);
                        }
                    }
                },
            )
            .map_err(e)?;

        // vec_add_scalar(vec_ptr, scalar_ptr, out_ptr, len)
        linker
            .func_wrap(
                "conjuredsp",
                "host_vec_add_scalar",
                |mut caller: Caller<'_, HostState>,
                 vec_ptr: i32, scalar_ptr: i32, out_ptr: i32, len: i32| {
                    if let Some(memory) = caller.get_export("memory").and_then(|e| e.into_memory()) {
                        let data = memory.data_mut(&mut caller);
                        let bytes = (len as usize) * 4;
                        let (v, s, o) = (vec_ptr as usize, scalar_ptr as usize, out_ptr as usize);
                        if v + bytes > data.len() || s + 4 > data.len() || o + bytes > data.len() {
                            return;
                        }
                        let base = data.as_mut_ptr();
                        unsafe {
                            vDSP_vsadd(
                                base.add(v) as *const f32, 1,
                                base.add(s) as *const f32,
                                base.add(o) as *mut f32, 1,
                                len as u32,
                            );
                        }
                    }
                },
            )
            .map_err(e)?;

        Ok(())
    }

    /// Non-macOS stub — conjuredsp host imports are not available.
    #[cfg(not(target_os = "macos"))]
    fn add_conjuredsp_imports(_linker: &mut Linker<HostState>) -> Result<(), String> {
        Ok(())
    }
}

impl Backend for WasmBackend {
    fn as_any_mut(&mut self) -> &mut dyn std::any::Any { self }

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
                    // Optional: get transport buffer address
                    if let Some(get_transport) = self.get_transport_ptr_fn.clone() {
                        if let Ok(ptr) = get_transport.call(&mut self.store, ()) {
                            self.transport_offset = ptr;
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
                        eprintln!("ConjureDSP-WASM: Failed to grow memory: {}", e);
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
        self.transport_offset = 0;
    }

    unsafe fn process(
        &mut self,
        inputs: &[*const f32],
        outputs: &[*mut f32],
        channel_count: usize,
        frame_count: usize,
        sample_rate: f64,
        params: &[f32; PARAM_COUNT],
        transport: &TransportState,
        sidechain: SidechainInput<'_>,
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

        // Copy input audio into WASM linear memory (bulk memcpy — both ARM64 and WASM are little-endian)
        let input_byte_offset = self.input_offset as usize;
        for ch in 0..channel_count {
            let src = std::slice::from_raw_parts(inputs[ch], frame_count);
            let dst_offset = input_byte_offset + ch * frame_count * 4;
            let dst = &mut mem_data[dst_offset..dst_offset + frame_count * 4];
            let src_bytes =
                std::slice::from_raw_parts(src.as_ptr() as *const u8, frame_count * 4);
            dst.copy_from_slice(src_bytes);
        }

        // Sidechain copy: same channel-sequential layout as the main
        // input bus, sized to MAX_FR per channel (the macro's static
        // allocation). Modules that don't declare sidechain leave
        // `sidechain_buf_offset` at None, so this whole block becomes a
        // no-op for legacy presets — zero overhead on the hot path.
        if let Some(offset) = self.sidechain_buf_offset {
            let sc_offset = offset as usize;
            // Per-channel stride mirrors the macro: MAX_FR f32s per ch
            // (not the runtime frame_count) so successive blocks always
            // land at the same offsets and the script-side accessor
            // can index by `channel * MAX_FR + frame`.
            let stride_bytes = conjuredsp::MAX_FRAMES * 4;
            let frame_bytes = frame_count * 4;
            let usable_ch = self
                .sidechain_max_channels
                .min(if sidechain.connected {
                    sidechain.channel_count
                } else {
                    self.sidechain_max_channels
                });
            for ch in 0..usable_ch {
                let dst_off = sc_offset + ch * stride_bytes;
                if dst_off + frame_bytes > mem_data.len() {
                    break;
                }
                let dst = &mut mem_data[dst_off..dst_off + frame_bytes];
                if sidechain.connected && ch < sidechain.channel_count {
                    let src = std::slice::from_raw_parts(
                        sidechain.inputs[ch],
                        frame_count,
                    );
                    let src_bytes = std::slice::from_raw_parts(
                        src.as_ptr() as *const u8,
                        frame_bytes,
                    );
                    dst.copy_from_slice(src_bytes);
                } else {
                    // Disconnected: zero the live block so scripts see
                    // silence instead of last block's audio. We only
                    // touch frame_count bytes — the remaining MAX_FR
                    // tail isn't read by the script's accessor.
                    for b in dst.iter_mut() {
                        *b = 0;
                    }
                }
            }
            // Publish sidechain state ([channel_count, connected]) so
            // the script can branch on whether the host actually wired
            // anything up. Layout is fixed — see the `sidechain!()`
            // story in conjuredsp-rs.
            if let Some(state_offset) = self.sidechain_state_offset {
                let state_off = state_offset as usize;
                if state_off + 8 <= mem_data.len() {
                    // Report `usable_ch`, not `sidechain.channel_count`:
                    // when the host pulls more channels than the script
                    // allocated for, only `usable_ch` were actually
                    // written into SIDECHAIN_BUF. Telling the script the
                    // raw count would invite reads of stale / zero
                    // channels above the buffer's capacity.
                    let ch_le = (usable_ch as i32).to_le_bytes();
                    let conn_le = (if sidechain.connected { 1i32 } else { 0i32 })
                        .to_le_bytes();
                    mem_data[state_off..state_off + 4].copy_from_slice(&ch_le);
                    mem_data[state_off + 4..state_off + 8].copy_from_slice(&conn_le);
                }
            }
        }

        // Write params into WASM memory if the module exports get_params_ptr.
        // Only write param_write_count entries to avoid overflowing the module's buffer.
        // If metadata exists, denormalize 0–1 to actual values (same as Python backend).
        if self.params_offset != 0 {
            let params_byte_offset = self.params_offset as usize;
            let write_count = self.param_write_count.min(params.len());
            let params_end = params_byte_offset + write_count * 4;
            if params_end <= mem_data.len() {
                for i in 0..write_count {
                    let val = if let Some(ref meta) = self.param_metadata {
                        if i < meta.len() {
                            meta[i].denormalize(params[i])
                        } else {
                            params[i]
                        }
                    } else {
                        params[i]
                    };
                    let offset = params_byte_offset + i * 4;
                    mem_data[offset..offset + 4].copy_from_slice(&val.to_le_bytes());
                }
            }
        }

        // Write transport data into WASM memory if the module exports get_transport_ptr.
        // Layout: [tempo_f32, beat_position_f32, is_playing_f32 (0/1), time_sig_num_f32, time_sig_den_f32, sample_position_f32]
        if self.transport_offset != 0 {
            let transport_byte_offset = self.transport_offset as usize;
            let transport_end = transport_byte_offset + 6 * 4;
            if transport_end <= mem_data.len() {
                let vals: [f32; 6] = [
                    transport.tempo as f32,
                    transport.beat_position as f32,
                    if transport.is_playing { 1.0 } else { 0.0 },
                    transport.time_sig_numerator as f32,
                    transport.time_sig_denominator as f32,
                    transport.sample_position as f32,
                ];
                let src_bytes = std::slice::from_raw_parts(
                    vals.as_ptr() as *const u8,
                    6 * 4,
                );
                mem_data[transport_byte_offset..transport_end].copy_from_slice(src_bytes);
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

        // Copy output audio from WASM linear memory (bulk memcpy — little-endian match)
        let mem_data = self.memory.data(&self.store);
        let output_byte_offset = self.output_offset as usize;

        for ch in 0..channel_count {
            let dst = std::slice::from_raw_parts_mut(outputs[ch], frame_count);
            let src_offset = output_byte_offset + ch * frame_count * 4;
            let src = &mem_data[src_offset..src_offset + frame_count * 4];
            let dst_bytes =
                std::slice::from_raw_parts_mut(dst.as_mut_ptr() as *mut u8, frame_count * 4);
            dst_bytes.copy_from_slice(src);
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

    fn latency_samples(&self) -> u32 {
        self.latency_samples
    }

    fn memory_bytes(&self) -> u64 {
        self.memory.data_size(&self.store) as u64
    }

    fn telemetry_metadata(&self) -> Option<&[crate::params::TelemetryMetadata]> {
        self.telemetry_metadata.as_deref()
    }

    fn read_telemetry(&self, out: &mut [f32; crate::params::TELEMETRY_LEN]) {
        // Skip the read entirely when the script declared no telemetry —
        // the buffer offset may exist (setup!() always exports it) but
        // there's no use exposing zeros to Swift if metadata is None.
        if self.telemetry_metadata.is_none() {
            return;
        }
        let Some(offset) = self.telemetry_buf_offset else {
            return;
        };
        let start = offset as usize;
        let byte_len = out.len() * core::mem::size_of::<f32>();
        let mem_data = self.memory.data(&self.store);
        let end = match start.checked_add(byte_len) {
            Some(e) if e <= mem_data.len() => e,
            _ => return,
        };
        let src = &mem_data[start..end];
        // Pointer cast is safe: src has byte_len = out.len() * 4 bytes.
        unsafe {
            let dst_bytes = core::slice::from_raw_parts_mut(
                out.as_mut_ptr() as *mut u8,
                byte_len,
            );
            dst_bytes.copy_from_slice(src);
        }
    }

    fn read_telemetry_vec(
        &self,
        slot_index: usize,
        frame_count: usize,
        out: &mut [f32],
    ) {
        // Same pure-memory-read pattern as `read_telemetry`: wasmtime
        // function calls require `&mut store`, so we cached the per-slot
        // base offsets at load time.
        let offset = match self.telemetry_vec_offsets.get(slot_index).and_then(|o| *o) {
            Some(o) => o,
            None => return,
        };
        let n = frame_count.min(out.len());
        if n == 0 {
            return;
        }
        let start = offset as usize;
        let byte_len = n * core::mem::size_of::<f32>();
        let mem_data = self.memory.data(&self.store);
        let end = match start.checked_add(byte_len) {
            Some(e) if e <= mem_data.len() => e,
            _ => return,
        };
        let src = &mem_data[start..end];
        unsafe {
            let dst_bytes = core::slice::from_raw_parts_mut(
                out.as_mut_ptr() as *mut u8,
                byte_len,
            );
            dst_bytes.copy_from_slice(src);
        }
    }
}

// MARK: - NAM model injection

impl WasmBackend {
    /// Returns the NAM model paths embedded in the WASM binary, in slot order.
    /// Empty when the module declares no NAM models.
    pub fn nam_paths(&self) -> &[String] {
        &self.nam_paths
    }

    /// Parse NAM model binary data and store natively in the given slot for
    /// host-side inference. The WASM module calls `__conjuredsp_nam_process_slot`
    /// which routes to this model when invoked with the matching slot index.
    pub fn inject_nam_model_slot(&mut self, slot: u32, binary_data: &[u8]) -> Result<(), String> {
        let model = conjuredsp::NamModel::from_binary(binary_data)
            .ok_or_else(|| "Failed to parse NAM model from binary data".to_string())?;
        let slot_idx = slot as usize;
        let models = &mut self.store.data_mut().nam_models;
        if slot_idx >= models.len() {
            return Err(format!(
                "NAM slot index {} out of range (module declared {} slot(s))",
                slot,
                models.len()
            ));
        }
        models[slot_idx] = Some(model);
        Ok(())
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
                &TransportState::default(),
            crate::backend::SidechainInput::NONE,
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
                &TransportState::default(),
            crate::backend::SidechainInput::NONE,
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
                &TransportState::default(),
            crate::backend::SidechainInput::NONE,
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
                &TransportState::default(),
            crate::backend::SidechainInput::NONE,
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
                &TransportState::default(),
            crate::backend::SidechainInput::NONE,
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
                    &TransportState::default(),
                crate::backend::SidechainInput::NONE,
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
                    &TransportState::default(),
                crate::backend::SidechainInput::NONE,
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
                &TransportState::default(),
            crate::backend::SidechainInput::NONE,
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
                &TransportState::default(),
            crate::backend::SidechainInput::NONE,
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
                &TransportState::default(),
            crate::backend::SidechainInput::NONE,
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
    fn test_wasm_param_metadata_from_export() {
        let json = r#"[{"name":"Rate","key":"rate","min":0.5,"max":20.0,"default":5.0,"unit":"Hz","curve":"linear"}]"#;
        let hex = json_to_wat_hex(json);
        let wat = format!(
            r#"
            (module
              (memory (export "memory") 1)
              (data (i32.const 1024) "{hex}")
              (func (export "process")
                (param $in i32) (param $out i32) (param $ch i32) (param $frames i32) (param $sr f32)
              )
              (func (export "get_param_metadata_ptr") (result i32)
                (i32.const 1024)
              )
              (func (export "get_param_metadata_len") (result i32)
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
        assert_eq!(names[&0], "Rate");
        let metadata = backend.param_metadata().expect("Should have metadata");
        assert_eq!(metadata.len(), 1);
        assert_eq!(metadata[0].name, "Rate");
        assert!((metadata[0].min - 0.5).abs() < 1e-6);
        assert!((metadata[0].max - 20.0).abs() < 1e-6);
    }

    #[test]
    fn test_wasm_telemetry_metadata_extracted() {
        // Two telemetry slots — backend should expose them via
        // `telemetry_metadata()`. The buffer-ptr export is also present
        // (placed elsewhere in memory) so `read_telemetry` works.
        // JSON uses verbatim macro identifiers (no canonicalization)
        // to match what the real `write_telemetry_json` emits.
        let json = r#"[{"name":"ENV_LEVEL","unit":""},{"name":"GR_DB","unit":"dB"}]"#;
        let hex = json_to_wat_hex(json);
        let wat = format!(
            r#"
            (module
              (memory (export "memory") 1)
              (data (i32.const 1024) "{hex}")
              (func (export "process")
                (param $in i32) (param $out i32) (param $ch i32) (param $frames i32) (param $sr f32)
              )
              (func (export "get_telemetry_metadata_ptr") (result i32) (i32.const 1024))
              (func (export "get_telemetry_metadata_len") (result i32) (i32.const {len}))
              (func (export "get_telemetry_buf_ptr") (result i32) (i32.const 2048))
            )
            "#,
            hex = hex,
            len = json.len(),
        );
        let wasm = wat_to_wasm(&wat);
        let backend = WasmBackend::load(&wasm).unwrap();
        let meta = backend.telemetry_metadata().expect("Should have telemetry metadata");
        assert_eq!(meta.len(), 2);
        assert_eq!(meta[0].name, "ENV_LEVEL");
        assert_eq!(meta[0].unit, "");
        assert_eq!(meta[1].name, "GR_DB");
        assert_eq!(meta[1].unit, "dB");
    }

    #[test]
    fn test_wasm_telemetry_buf_roundtrip() {
        // process() writes f32 values into TELEMETRY_BUF at offset 2048.
        // Slot 0: 0.5 (bits 0x3f000000), slot 1: -3.25 (bits 0xc0500000).
        let json = r#"[{"name":"A","unit":""},{"name":"B","unit":"dB"}]"#;
        let hex = json_to_wat_hex(json);
        let wat = format!(
            r#"
            (module
              (memory (export "memory") 1)
              (data (i32.const 1024) "{hex}")
              (func (export "process")
                (param $in i32) (param $out i32) (param $ch i32) (param $frames i32) (param $sr f32)
                (f32.store (i32.const 2048) (f32.const 0.5))
                (f32.store (i32.const 2052) (f32.const -3.25))
              )
              (func (export "get_telemetry_metadata_ptr") (result i32) (i32.const 1024))
              (func (export "get_telemetry_metadata_len") (result i32) (i32.const {len}))
              (func (export "get_telemetry_buf_ptr") (result i32) (i32.const 2048))
            )
            "#,
            hex = hex,
            len = json.len(),
        );
        let wasm = wat_to_wasm(&wat);
        let mut backend = WasmBackend::load(&wasm).unwrap();
        backend.initialize(2, 48000.0, 256);

        // Drive one process() call so the f32.store instructions execute.
        let in_buf = vec![0.0_f32; 256];
        let mut out_buf = vec![0.0_f32; 256];
        let inputs: [*const f32; 1] = [in_buf.as_ptr()];
        let outputs: [*mut f32; 1] = [out_buf.as_mut_ptr()];
        let params = [0.0_f32; PARAM_COUNT];
        let transport = crate::kernel::TransportState::default();
        unsafe {
            backend.process(&inputs, &outputs, 1, 256, 48000.0, &params, &transport, crate::backend::SidechainInput::NONE);
        }

        let mut tele = [0.0_f32; crate::params::TELEMETRY_LEN];
        backend.read_telemetry(&mut tele);
        assert_eq!(tele[0], 0.5);
        assert_eq!(tele[1], -3.25);
        // Slots not written by the script remain zero.
        assert_eq!(tele[2], 0.0);
        assert_eq!(tele[7], 0.0);
    }

    #[test]
    fn test_wasm_no_telemetry_exports_returns_none() {
        // Module without any telemetry exports — backend reports None
        // and `read_telemetry` is a no-op.
        let backend = WasmBackend::load(&wat_to_wasm(GAIN_HALF_WAT)).unwrap();
        assert!(backend.telemetry_metadata().is_none());
        let mut tele = [42.0_f32; crate::params::TELEMETRY_LEN];
        backend.read_telemetry(&mut tele);
        // Untouched — caller's sentinel survives.
        assert!(tele.iter().all(|&v| v == 42.0));
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

    #[test]
    fn test_wasm_memory_bytes_initial() {
        let wasm = wat_to_wasm(GAIN_HALF_WAT);
        let backend = WasmBackend::load(&wasm).unwrap();
        // GAIN_HALF_WAT declares (memory 1) = 1 page = 64KB
        assert_eq!(backend.memory_bytes(), 65536);
    }

    #[test]
    fn test_wasm_memory_bytes_grows() {
        // Module that grows memory by 1 page each process() call
        let wat = r#"
            (module
              (memory (export "memory") 1)
              (func (export "process")
                (param $in i32) (param $out i32) (param $ch i32) (param $frames i32) (param $sr f32)
                (drop (memory.grow (i32.const 1)))
              )
            )
        "#;
        let wasm = wat_to_wasm(wat);
        let mut backend = WasmBackend::load(&wasm).unwrap();
        backend.initialize(1, 44100.0, 1024);

        assert_eq!(backend.memory_bytes(), 65536);

        let input: [f32; 4] = [0.0; 4];
        let mut output: [f32; 4] = [0.0; 4];
        let params = [0.0f32; PARAM_COUNT];
        let transport = TransportState::default();

        unsafe {
            backend.process(
                &[input.as_ptr()],
                &[output.as_mut_ptr()],
                1, 4, 44100.0, &params, &transport, crate::backend::SidechainInput::NONE,
            );
        }
        assert_eq!(backend.memory_bytes(), 65536 * 2, "should grow by 1 page after process");

        unsafe {
            backend.process(
                &[input.as_ptr()],
                &[output.as_mut_ptr()],
                1, 4, 44100.0, &params, &transport, crate::backend::SidechainInput::NONE,
            );
        }
        assert_eq!(backend.memory_bytes(), 65536 * 3, "should grow by another page");
    }

    #[test]
    fn test_nam_inject_rejects_too_small() {
        let wasm = wat_to_wasm(BUFFER_GETTERS_WAT);
        let mut backend = WasmBackend::load(&wasm).unwrap();

        // BUFFER_GETTERS_WAT has no NAM declaration, so slot 0 is out of range —
        // assert the bounds check fires before we even parse the binary.
        let tiny = vec![0u8; 8];
        let result = backend.inject_nam_model_slot(0, &tiny);
        assert!(result.is_err(), "Should reject inject into module with no slots");
    }

    #[test]
    fn test_nam_host_import_end_to_end() {
        // Load the pre-compiled WASM module that uses nam!() with host import
        let wasm_path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../tmp_test_nam_e2e.wasm");

        // Compile the test WASM inline
        let rustc = concat!(env!("CARGO_MANIFEST_DIR"), "/../../rustc-dist/bin/rustc");
        let sysroot = concat!(env!("CARGO_MANIFEST_DIR"), "/../../rustc-dist");
        let rlib = concat!(env!("CARGO_MANIFEST_DIR"), "/../../rustc-dist/lib/libconjuredsp.rlib");

        if !std::path::Path::new(rustc).exists() {
            eprintln!("Skipping: bundled rustc not found");
            return;
        }

        let src = r#"
use conjuredsp::*;
setup!();
nam!("tone3000://test/model");
params! { GAIN = db().default(0.0), }
#[no_mangle]
pub extern "C" fn process(
    input: *const f32, output: *mut f32,
    channel_count: i32, frame_count: i32, sample_rate: f32,
) {
    let ctx = ctx(input, output, channel_count, frame_count, sample_rate);
    unsafe {
        for c in 0..ctx.channels() {
            let n = ctx.frames();
            for i in 0..n { NAM_IN[i] = ctx.input(c, i); }
            nam_process(&NAM_IN[..n], &mut NAM_OUT[..n], c);
            for i in 0..n { ctx.set_output(c, i, NAM_OUT[i]); }
        }
    }
}
fn main() {}
"#;
        let src_path = format!("{}/../../tmp_test_nam_src.rs", env!("CARGO_MANIFEST_DIR"));
        std::fs::write(&src_path, src).unwrap();

        let output = std::process::Command::new(rustc)
            .args(&["--target", "wasm32-wasip1", "--edition", "2021",
                    "--crate-type", "cdylib", "-C", "opt-level=2",
                    "--sysroot", sysroot,
                    "--extern", &format!("conjuredsp={}", rlib),
                    "-o", wasm_path, &src_path])
            .output()
            .expect("Failed to run rustc");
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            panic!("WASM compilation failed: {}", stderr);
        }

        let wasm_bytes = std::fs::read(wasm_path).expect("Failed to read compiled WASM");
        let _ = std::fs::remove_file(wasm_path);
        let _ = std::fs::remove_file(&src_path);

        // Load WASM module
        let mut backend = WasmBackend::load(&wasm_bytes)
            .expect("Failed to load NAM WASM module");

        // Verify nam_paths is detected (single-slot legacy nam!() macro)
        assert_eq!(backend.nam_paths(), &["tone3000://test/model".to_string()],
            "Should detect NAM path from WASM exports");

        // Build NAM binary protocol from test model
        let nam_path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../tone3000_py_demo/wavenet_tiny.nam");
        if !std::path::Path::new(nam_path).exists() {
            eprintln!("Skipping: wavenet_tiny.nam not found");
            return;
        }
        let nam_binary = serialize_nam_file_to_binary(nam_path);

        // Inject model into slot 0 (the legacy `nam!()` macro declares one slot)
        backend.inject_nam_model_slot(0, &nam_binary)
            .expect("Failed to inject NAM model");

        // Initialize
        backend.initialize(1, 48000.0, 512);

        // Process a sine wave
        let n = 512;
        let input: Vec<f32> = (0..n)
            .map(|i| (2.0 * std::f32::consts::PI * 440.0 * i as f32 / 48000.0).sin() * 0.5)
            .collect();
        let mut output = vec![0.0f32; n];
        let params = [0.0f32; 16]; // GAIN = 0dB (normalized 0.5 for [-12, 12] range)
        let transport = crate::kernel::TransportState::default();

        let ok = unsafe {
            backend.process(
                &[input.as_ptr()], &[output.as_mut_ptr()],
                1, n, 48000.0, &params, &transport, crate::backend::SidechainInput::NONE,
            )
        };
        assert!(ok, "Process should succeed");

        // Also compute the expected output directly with native NamModel
        let mut native_model = conjuredsp::NamModel::from_binary(&nam_binary)
            .expect("Failed to parse NAM model natively");
        let mut expected = vec![0.0f32; n];
        native_model.process_buffer(&input, &mut expected, 0);

        // Compare
        let mut max_err = 0.0f32;
        let mut max_err_idx = 0;
        for i in 0..n {
            let err = (output[i] - expected[i]).abs();
            if err > max_err {
                max_err = err;
                max_err_idx = i;
            }
        }

        let out_rms = (output.iter().map(|x| x * x).sum::<f32>() / n as f32).sqrt();
        let exp_rms = (expected.iter().map(|x| x * x).sum::<f32>() / n as f32).sqrt();

        eprintln!("WASM→host NAM e2e: max_err={:.6} at [{}]", max_err, max_err_idx);
        eprintln!("  Output RMS: {:.6}, Expected RMS: {:.6}", out_rms, exp_rms);
        eprintln!("  First 5 output:   {:?}", &output[..5]);
        eprintln!("  First 5 expected: {:?}", &expected[..5]);

        assert!(out_rms > 1e-4,
            "Output is silent (RMS={}) — host import may not be called", out_rms);
        assert!(max_err < 1e-3,
            "WASM→host NAM parity failed: max_err={:.6} at [{}] (out={:.6}, exp={:.6})",
            max_err, max_err_idx, output[max_err_idx], expected[max_err_idx]);
    }

    #[test]
    fn test_nam_multi_slot_end_to_end() {
        // Compile a WASM module that uses `nams!{ A=..., B=... }` and cascades
        // input through both slots in series. We then inject the SAME tiny
        // WaveNet model into both slots and verify the output matches a native
        // double-pass (model.process_buffer applied twice). This exercises:
        //   - manifest parsing of multiple paths
        //   - slot index constants from `nams!`
        //   - per-slot inject + per-slot host import dispatch
        //   - per-slot independent model state (each slot maintains its own history)
        let wasm_path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../tmp_test_nam_multi.wasm");
        let rustc = concat!(env!("CARGO_MANIFEST_DIR"), "/../../rustc-dist/bin/rustc");
        let sysroot = concat!(env!("CARGO_MANIFEST_DIR"), "/../../rustc-dist");
        let rlib = concat!(env!("CARGO_MANIFEST_DIR"), "/../../rustc-dist/lib/libconjuredsp.rlib");

        if !std::path::Path::new(rustc).exists() {
            eprintln!("Skipping: bundled rustc not found");
            return;
        }

        let src = r#"
use conjuredsp::*;
setup!();
nams! {
    A = "tone3000://test/a",
    B = "tone3000://test/b",
}
#[no_mangle]
pub extern "C" fn process(
    input: *const f32, output: *mut f32,
    channel_count: i32, frame_count: i32, sample_rate: f32,
) {
    let ctx = ctx(input, output, channel_count, frame_count, sample_rate);
    let mut buf_a = [0.0_f32; MAX_FR];
    let mut buf_b = [0.0_f32; MAX_FR];
    unsafe {
        for c in 0..ctx.channels() {
            let n = ctx.frames();
            for i in 0..n { buf_a[i] = ctx.input(c, i); }
            nam_process_slot(A, &buf_a[..n], &mut buf_b[..n], c);
            nam_process_slot(B, &buf_b[..n], &mut buf_a[..n], c);
            for i in 0..n { ctx.set_output(c, i, buf_a[i]); }
        }
    }
}
fn main() {}
"#;
        let src_path = format!("{}/../../tmp_test_nam_multi_src.rs", env!("CARGO_MANIFEST_DIR"));
        std::fs::write(&src_path, src).unwrap();

        let output = std::process::Command::new(rustc)
            .args(&["--target", "wasm32-wasip1", "--edition", "2021",
                    "--crate-type", "cdylib", "-C", "opt-level=2",
                    "--sysroot", sysroot,
                    "--extern", &format!("conjuredsp={}", rlib),
                    "-o", wasm_path, &src_path])
            .output()
            .expect("Failed to run rustc");
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            panic!("Multi-slot WASM compilation failed: {}", stderr);
        }

        let wasm_bytes = std::fs::read(wasm_path).expect("Failed to read compiled WASM");
        let _ = std::fs::remove_file(wasm_path);
        let _ = std::fs::remove_file(&src_path);

        let mut backend = WasmBackend::load(&wasm_bytes)
            .expect("Failed to load multi-slot NAM WASM module");

        // Manifest must report both slots in declaration order.
        assert_eq!(
            backend.nam_paths(),
            &["tone3000://test/a".to_string(), "tone3000://test/b".to_string()],
            "Should detect both NAM paths from manifest",
        );

        // Out-of-range slot must fail gracefully on inject.
        let dummy = vec![0u8; 8];
        assert!(
            backend.inject_nam_model_slot(99, &dummy).is_err(),
            "Out-of-range slot inject must error",
        );

        // Inject same tiny WaveNet model into both slots.
        let nam_path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../tone3000_py_demo/wavenet_tiny.nam");
        if !std::path::Path::new(nam_path).exists() {
            eprintln!("Skipping: wavenet_tiny.nam not found");
            return;
        }
        let nam_binary = serialize_nam_file_to_binary(nam_path);
        backend.inject_nam_model_slot(0, &nam_binary).expect("inject slot 0");
        backend.inject_nam_model_slot(1, &nam_binary).expect("inject slot 1");

        backend.initialize(1, 48000.0, 512);

        let n = 512;
        let input: Vec<f32> = (0..n)
            .map(|i| (2.0 * std::f32::consts::PI * 440.0 * i as f32 / 48000.0).sin() * 0.5)
            .collect();
        let mut output = vec![0.0f32; n];
        let params = [0.0f32; 16];
        let transport = crate::kernel::TransportState::default();

        let ok = unsafe {
            backend.process(
                &[input.as_ptr()], &[output.as_mut_ptr()],
                1, n, 48000.0, &params, &transport, crate::backend::SidechainInput::NONE,
            )
        };
        assert!(ok, "Process should succeed");

        // Native parity: same model applied twice in series, with each pass
        // owning its own NamModel instance (matches the per-slot state model).
        let mut native_a = conjuredsp::NamModel::from_binary(&nam_binary)
            .expect("Failed to parse NAM model natively (a)");
        let mut native_b = conjuredsp::NamModel::from_binary(&nam_binary)
            .expect("Failed to parse NAM model natively (b)");
        let mut intermediate = vec![0.0f32; n];
        let mut expected = vec![0.0f32; n];
        native_a.process_buffer(&input, &mut intermediate, 0);
        native_b.process_buffer(&intermediate, &mut expected, 0);

        let mut max_err = 0.0f32;
        let mut max_err_idx = 0;
        for i in 0..n {
            let err = (output[i] - expected[i]).abs();
            if err > max_err { max_err = err; max_err_idx = i; }
        }

        let out_rms = (output.iter().map(|x| x * x).sum::<f32>() / n as f32).sqrt();
        let exp_rms = (expected.iter().map(|x| x * x).sum::<f32>() / n as f32).sqrt();

        eprintln!(
            "WASM→host NAM multi-slot e2e: max_err={:.6} at [{}], out_rms={:.6}, exp_rms={:.6}",
            max_err, max_err_idx, out_rms, exp_rms,
        );

        assert!(
            out_rms > 1e-4,
            "Output is silent (RMS={}) — multi-slot host import may not be called",
            out_rms,
        );
        assert!(
            max_err < 1e-3,
            "Multi-slot NAM parity failed: max_err={:.6} at [{}] (out={:.6}, exp={:.6})",
            max_err, max_err_idx, output[max_err_idx], expected[max_err_idx],
        );

        // Verify that an unloaded slot returns 0 from the host import (call into
        // a fresh backend with paths declared but slot 1 left empty).
        let mut backend2 = WasmBackend::load(&wasm_bytes).expect("reload module");
        backend2.inject_nam_model_slot(0, &nam_binary).expect("inject slot 0 only");
        backend2.initialize(1, 48000.0, 512);
        let mut output2 = vec![0.0f32; n];
        let ok2 = unsafe {
            backend2.process(
                &[input.as_ptr()], &[output2.as_mut_ptr()],
                1, n, 48000.0, &params, &transport, crate::backend::SidechainInput::NONE,
            )
        };
        assert!(ok2, "Process should succeed even with empty slot");
        // With slot B empty, slot A wrote into buf_b but slot B's call returned 0
        // and left buf_a untouched (still holding the original input from the
        // pre-loop copy in process()). So the output should equal the input.
        let mut max_in_diff = 0.0f32;
        for i in 0..n {
            let d = (output2[i] - input[i]).abs();
            if d > max_in_diff { max_in_diff = d; }
        }
        assert!(
            max_in_diff < 1e-6,
            "Empty slot should leave output buffer untouched (max_in_diff={:.6})",
            max_in_diff,
        );
    }

    /// Serialize a .nam JSON file to the binary protocol (same as Swift's injectNamModelIfNeeded).
    fn serialize_nam_file_to_binary(path: &str) -> Vec<u8> {
        let json_str = std::fs::read_to_string(path).unwrap();

        // Extract architecture
        let arch_start = json_str.find("\"architecture\"").unwrap();
        let arch_val_start = json_str[arch_start..].find(':').unwrap() + arch_start + 1;
        let arch_str_start = json_str[arch_val_start..].find('"').unwrap() + arch_val_start + 1;
        let arch_str_end = json_str[arch_str_start..].find('"').unwrap() + arch_str_start;
        let architecture = &json_str[arch_str_start..arch_str_end];

        let sample_rate: f32 = if let Some(sr_start) = json_str.find("\"sample_rate\"") {
            let sr_val_start = json_str[sr_start..].find(':').unwrap() + sr_start + 1;
            let sr_val_str = json_str[sr_val_start..].trim_start();
            let sr_end = sr_val_str.find(|c: char| !c.is_ascii_digit() && c != '.').unwrap_or(sr_val_str.len());
            sr_val_str[..sr_end].trim().parse().unwrap_or(48000.0)
        } else {
            48000.0
        };

        // Extract config object
        let config_key = json_str.find("\"config\"").unwrap();
        let config_colon = json_str[config_key..].find(':').unwrap() + config_key + 1;
        let config_start = json_str[config_colon..].find('{').unwrap() + config_colon;
        let mut depth = 0;
        let mut config_end = config_start;
        for (i, c) in json_str[config_start..].chars().enumerate() {
            match c { '{' => depth += 1, '}' => { depth -= 1; if depth == 0 { config_end = config_start + i + 1; break; } } _ => {} }
        }
        let config_json = &json_str[config_start..config_end];

        // Re-serialize config through serde_json (mimics Swift JSONSerialization)
        let config_value: serde_json::Value = serde_json::from_str(config_json).unwrap();
        let config_bytes = serde_json::to_vec(&config_value).unwrap();

        // Extract weights
        let weights_key = json_str.find("\"weights\"").unwrap();
        let weights_bracket = json_str[weights_key..].find('[').unwrap() + weights_key;
        let weights_end = json_str[weights_bracket..].find(']').unwrap() + weights_bracket + 1;
        let weights_str = &json_str[weights_bracket + 1..weights_end - 1];
        let weights: Vec<f32> = weights_str.split(',')
            .filter_map(|s| s.trim().parse::<f64>().ok())
            .map(|v| v as f32)
            .collect();

        // Build binary protocol
        let arch: u32 = if architecture == "LSTM" { 1 } else { 0 };
        let mut binary = Vec::new();
        binary.extend_from_slice(&arch.to_le_bytes());
        binary.extend_from_slice(&sample_rate.to_bits().to_le_bytes());
        binary.extend_from_slice(&(config_bytes.len() as u32).to_le_bytes());
        binary.extend_from_slice(&config_bytes);
        binary.extend_from_slice(&(weights.len() as u32).to_le_bytes());
        for w in &weights {
            binary.extend_from_slice(&w.to_bits().to_le_bytes());
        }
        binary
    }
}
