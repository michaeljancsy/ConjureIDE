use crate::backend::{Backend, SidechainInput, StateSnapshot};
use crate::kernel::TransportState;
use crate::params::{ParamMetadata, TelemetryMetadata, PARAM_COUNT, TELEMETRY_LEN};
use numpy::{PyArray1, PyArray2, PyArrayMethods};
use pyo3::prelude::*;
use pyo3::types::{PyDict, PyList, PySlice};
use std::collections::HashMap;
use std::ffi::CString;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::OnceLock;

/// Global counter for generating unique Python module names per backend instance.
/// Each PythonBackend gets its own module in sys.modules, preventing collisions
/// when multiple AU instances load different scripts in the same DAW process.
static INSTANCE_COUNTER: AtomicU64 = AtomicU64::new(0);

/// Ensures PYTHONHOME and PYTHONDONTWRITEBYTECODE are set exactly once,
/// avoiding the POSIX setenv() thread-safety issue when multiple AU instances
/// initialize concurrently (e.g., DAW track duplication).
static PYTHON_ENV_INIT: OnceLock<()> = OnceLock::new();

/// Python DSP backend using pyo3 and numpy.
///
/// Loads a Python script containing a single-arg `process(ctx)` function
/// and calls it each render callback. The `ctx` object is built once at
/// `initialize()` time and mutated in place per block — its attributes:
///
///   `inputs`        2D `numpy.ndarray[float32]` of shape
///                   `(channel_count, max_frames)` — row `ch` is the
///                   per-channel buffer
///   `outputs`       2D `numpy.ndarray[float32]` of shape
///                   `(channel_count, max_frames)`
///   `sidechain`     2D `numpy.ndarray[float32]` (always present;
///                   zero-filled when nothing is routed). The trailing
///                   `[:, frame_count..]` slack region of any of these
///                   carries stale data from previous blocks and is
///                   undefined; do not read past `frame_count`.
///   `params`        read-only mapping (denormalized values keyed by
///                   declared name, or 0–1 indexed list in legacy mode)
///   `state`         read-only mapping over bundle-private persisted JSON
///                   (re-parsed only when the kernel's state generation
///                   bumps; cached otherwise)
///   `telemetry`     writable dict for `ctx.telemetry["x"] = …` writes
///   `transport`     read-only namespace with `bpm`, `beat`,
///                   `is_playing`, `time_sig_numerator`,
///                   `time_sig_denominator`, `sample_position`
///   `sample_rate`   float
///   `frame_count`   int
///
/// Scripts whose `process` doesn't take exactly one positional arg are
/// rejected at load time with a clear error.
pub struct PythonBackend {
    py_process_fn: Py<PyAny>,
    /// The single ctx object passed to process(). Rebuilt on channel-
    /// count or max-frames change; mutated in place each block.
    py_ctx: Option<Py<PyAny>>,
    /// 2D backing array for `ctx.inputs`, shape `(channel_count, max_frames)`.
    /// `None` until `allocate_py_arrays` runs at `initialize()`.
    py_input_array: Option<Py<PyArray2<f32>>>,
    /// 2D backing array for `ctx.outputs`.
    py_output_array: Option<Py<PyArray2<f32>>>,
    /// 2D backing array for `ctx.sidechain` (always allocated; zero-filled
    /// when host has nothing routed).
    py_sidechain_array: Option<Py<PyArray2<f32>>>,
    /// Cached `slice(None)` (i.e. `:`) — never changes across the backend's
    /// lifetime. Used to build the 2D sliced views `backing[:, :frame_count]`
    /// that the script sees as `ctx.inputs` / `outputs` / `sidechain`.
    cached_full_slice: Option<Py<PySlice>>,
    /// Cached `slice(0, frame_count, 1)`. Rebuilt only when `frame_count`
    /// changes; reused across blocks where it doesn't (the common case).
    cached_prefix_slice: Option<Py<PySlice>>,
    /// `frame_count` value the cached prefix slice was built for.
    /// `u32::MAX` is the sentinel that forces a rebuild on the first block
    /// after allocate / channel resize — using `0` here would skip the
    /// rebuild when the host calls with `frame_count == 0`, leaving
    /// `cached_prefix_slice` unwrappable.
    cached_prefix_for_frames: u32,
    last_error: Option<String>,
    param_names: HashMap<u8, String>,
    /// Rich parameter metadata from `PARAMS` dict. When present, ctx.params
    /// is a read-only dict of denormalized values; otherwise it's a
    /// read-only list of 0–1 floats.
    param_metadata: Option<Vec<ParamMetadata>>,
    /// Script-declared telemetry slot metadata (from `TELEMETRY` dict).
    telemetry_metadata: Option<Vec<TelemetryMetadata>>,
    /// The same dict object exposed as `ctx.telemetry` — pre-seeded with
    /// `0.0` for each declared slot so script writes are dict updates.
    py_telemetry_dict: Option<Py<PyAny>>,
    /// The dict that `ctx.params`'s `conjuredsp._ctx.ParamsView` wraps
    /// (rich-metadata mode only). Cached so the per-block update mutates
    /// this dict in place instead of allocating a fresh dict + view each
    /// callback. The `ParamsView` on `ctx.params` holds the same dict by
    /// reference, so script reads see updated values without us touching
    /// the view object.
    py_params_dict: Option<Py<PyAny>>,
    /// Per-block telemetry snapshot the kernel reads via `read_telemetry`.
    telemetry_buf: [f32; TELEMETRY_LEN],
    /// Max frames the host may pass to `process()`.
    py_max_frames: usize,
    /// Script-declared algorithmic latency in samples.
    latency_samples: u32,
    /// Script-declared `STATE` dict at load time (the per-instance
    /// defaults). The Swift coordinator pushes these into the kernel
    /// via `dsp_kernel_set_state_json` at script load before any UI
    /// has a chance to write.
    state_defaults_json: Option<String>,
    /// Per-script byte cap for state. Exposed via `state_max_bytes()`
    /// so Swift can plumb it through `dsp_kernel_set_state_cap`. Python
    /// presets currently have no opt-in syntax — defaults to None and
    /// the coordinator falls back to `DEFAULT_STATE_CAP_BYTES`.
    state_max_bytes: Option<usize>,
    /// Cached generation of the state buffer last parsed into
    /// `py_state_dict`. Initialized to a sentinel `u64::MAX` so the
    /// first block always re-parses (even when the buffer hasn't
    /// changed) — that ensures `ctx.state` reflects either the
    /// persisted state OR the script defaults from the moment the
    /// first block runs.
    py_state_gen: u64,
    /// Read-only mapping wrapped via `MappingProxyType` — what
    /// `ctx.state` returns. Re-built on every gen bump from the
    /// underlying parsed dict so script attempts to mutate raise
    /// `AttributeError`.
    py_state_dict: Option<Py<PyAny>>,
    /// Set of declared STATE keys (used for "unknown persisted key"
    /// logging at script load).
    state_declared_keys: Vec<String>,
    /// Unique module name in sys.modules.
    module_name: String,
}

impl Drop for PythonBackend {
    fn drop(&mut self) {
        // Remove our module from sys.modules so Python can GC it.
        Python::with_gil(|py| {
            if let Ok(sys) = py.import("sys") {
                if let Ok(modules) = sys.getattr("modules") {
                    let _ = modules.call_method1("pop", (self.module_name.as_str(), py.None()));
                }
            }
        });
    }
}

impl PythonBackend {
    /// Prepend a directory to Python's `sys.path` so packages in it are importable.
    pub fn inject_site_packages(path: &str) -> Result<(), String> {
        Python::with_gil(|py| -> Result<(), PyErr> {
            let sys = py.import("sys")?;
            let path_list = sys.getattr("path")?;
            let contains: bool = path_list
                .call_method1("__contains__", (path,))?
                .extract()?;
            if !contains {
                path_list.call_method1("insert", (0i32, path))?;
            }
            Ok(())
        })
        .map_err(|e| e.to_string())
    }

    /// Load a Python script containing a `process(ctx)` function.
    pub fn load(python_home: &str, script_path: &str) -> Result<Self, String> {
        eprintln!(
            "ConjureDSP-Rust: PythonBackend::load called, python_home={}, script_path={}",
            python_home, script_path
        );

        let python_home_owned = python_home.to_string();
        PYTHON_ENV_INIT.get_or_init(|| {
            std::env::set_var("PYTHONHOME", &python_home_owned);
            std::env::set_var("PYTHONDONTWRITEBYTECODE", "1");
        });

        struct LoadResult {
            process_fn: Py<PyAny>,
            param_names: HashMap<u8, String>,
            param_metadata: Option<Vec<ParamMetadata>>,
            telemetry_metadata: Option<Vec<TelemetryMetadata>>,
            latency: u32,
            state_defaults_json: Option<String>,
            state_declared_keys: Vec<String>,
            state_max_bytes: Option<usize>,
            module_name: String,
        }

        let result: Result<LoadResult, PyErr> = Python::with_gil(|py| {
            let code = std::fs::read_to_string(script_path)
                .map_err(|e| pyo3::exceptions::PyIOError::new_err(e.to_string()))?;

            let code_c = CString::new(code)
                .map_err(|e| pyo3::exceptions::PyValueError::new_err(e.to_string()))?;
            let path_c = CString::new(script_path)
                .map_err(|e| pyo3::exceptions::PyValueError::new_err(e.to_string()))?;

            let instance_id = INSTANCE_COUNTER.fetch_add(1, Ordering::Relaxed);
            let mod_name_str = format!("dsp_script_{}", instance_id);
            let module_name = CString::new(mod_name_str.as_str())
                .map_err(|e| pyo3::exceptions::PyValueError::new_err(e.to_string()))?;

            let sys = py.import("sys")?;
            let sys_modules = sys.getattr("modules")?;
            let _ = sys_modules.call_method1("pop", (mod_name_str.as_str(), py.None()));

            let module = PyModule::from_code(py, &code_c, &path_c, &module_name)?;
            let process_fn = module.getattr("process")?;

            // Single-arg ctx signature is the only accepted shape. Old
            // 7- and 8-arg forms are rejected at load time so authors
            // don't see a confusing TypeError every render block.
            let arity: usize = process_fn
                .getattr("__code__")?
                .getattr("co_argcount")?
                .extract()?;
            if arity != 1 {
                return Err(pyo3::exceptions::PyTypeError::new_err(format!(
                    "process() must take exactly one argument (ctx); got {} args. \
                    Migrate from the legacy positional form: \
                    `def process(ctx):` and read inputs/outputs/params/state/etc. \
                    via `ctx.inputs[0]`, `ctx.params[\"name\"]`, `ctx.state[\"key\"]`.",
                    arity
                )));
            }

            let (param_names, param_metadata) = Self::extract_params(py, &module);
            let telemetry_metadata = Self::extract_telemetry(&module);

            let latency: u32 = module
                .getattr("LATENCY")
                .ok()
                .and_then(|v| v.extract::<u32>().ok())
                .unwrap_or(0);

            // STATE defaults: script-declared per-instance persistent state.
            // Serialized to a JSON string here; the Swift coordinator
            // installs it as the kernel's initial state buffer for fresh
            // instances. Re-loading the same preset re-applies these
            // defaults; loading from a DAW project session restores the
            // saved state instead.
            let (state_defaults_json, state_declared_keys) = Self::extract_state_defaults(&module);

            // Optional opt-in: script can declare a custom byte cap as
            // a module-level constant `STATE_MAX_BYTES = N`.
            let state_max_bytes = module
                .getattr("STATE_MAX_BYTES")
                .ok()
                .and_then(|v| v.extract::<usize>().ok());

            Ok(LoadResult {
                process_fn: process_fn.unbind(),
                param_names,
                param_metadata,
                telemetry_metadata,
                latency,
                state_defaults_json,
                state_declared_keys,
                state_max_bytes,
                module_name: mod_name_str,
            })
        });

        match result {
            Ok(r) => {
                eprintln!(
                    "ConjureDSP-Rust: Python script loaded successfully (latency={}, state_keys={})",
                    r.latency,
                    r.state_declared_keys.len()
                );
                Ok(Self {
                    py_process_fn: r.process_fn,
                    py_ctx: None,
                    py_input_array: None,
                    py_output_array: None,
                    py_sidechain_array: None,
                    cached_full_slice: None,
                    cached_prefix_slice: None,
                    cached_prefix_for_frames: u32::MAX,
                    last_error: None,
                    param_names: r.param_names,
                    param_metadata: r.param_metadata,
                    telemetry_metadata: r.telemetry_metadata,
                    py_telemetry_dict: None,
                    py_params_dict: None,
                    telemetry_buf: [0.0; TELEMETRY_LEN],
                    py_max_frames: 0,
                    latency_samples: r.latency,
                    state_defaults_json: r.state_defaults_json,
                    state_max_bytes: r.state_max_bytes,
                    py_state_gen: u64::MAX, // force initial parse
                    py_state_dict: None,
                    state_declared_keys: r.state_declared_keys,
                    module_name: r.module_name,
                })
            }
            Err(e) => {
                let py_err_msg = Python::with_gil(|py| {
                    let tb_str = e
                        .traceback(py)
                        .and_then(|tb| tb.format().ok())
                        .unwrap_or_default();
                    let msg = e.value(py).to_string();
                    e.print(py);
                    if tb_str.is_empty() {
                        msg
                    } else {
                        format!("{}{}", tb_str, msg)
                    }
                });
                let err_msg = format!(
                    "{}\n\npython_home: {}\nscript_path: {}",
                    py_err_msg, python_home, script_path
                );
                Err(err_msg)
            }
        }
    }

    /// JSON for the script's declared `STATE = {…}` defaults, or `None`
    /// when the script declared none. Swift uses this to seed the
    /// kernel's state buffer at script load.
    pub fn state_defaults_json(&self) -> Option<&str> {
        self.state_defaults_json.as_deref()
    }

    /// Optional script-declared byte cap (`STATE_MAX_BYTES = N`).
    pub fn state_max_bytes(&self) -> Option<usize> {
        self.state_max_bytes
    }

    /// Names of every key declared in the script's `STATE` dict, in
    /// declaration order. Used by the validator and the smoke tester to
    /// resolve `ConjureDSP.state.get/set` references against the script.
    pub fn state_declared_keys(&self) -> &[String] {
        &self.state_declared_keys
    }

    fn extract_params(
        py: Python<'_>,
        module: &Bound<'_, PyModule>,
    ) -> (HashMap<u8, String>, Option<Vec<ParamMetadata>>) {
        if let Ok(attr) = module.getattr("PARAMS") {
            if let Ok(dict) = attr.downcast::<PyDict>() {
                let mut metadata = Vec::new();
                let mut names = HashMap::new();
                for (i, (key, val)) in dict.iter().enumerate() {
                    if i >= PARAM_COUNT {
                        break;
                    }
                    let name = match key.extract::<String>() {
                        Ok(n) => n,
                        Err(_) => continue,
                    };
                    if let Ok(spec) = val.downcast::<PyDict>() {
                        let min = spec
                            .get_item("min")
                            .ok()
                            .flatten()
                            .and_then(|v| v.extract::<f32>().ok())
                            .unwrap_or(0.0);
                        let max = spec
                            .get_item("max")
                            .ok()
                            .flatten()
                            .and_then(|v| v.extract::<f32>().ok())
                            .unwrap_or(1.0);
                        let default = spec
                            .get_item("default")
                            .ok()
                            .flatten()
                            .and_then(|v| v.extract::<f32>().ok())
                            .unwrap_or(min);
                        let unit = spec
                            .get_item("unit")
                            .ok()
                            .flatten()
                            .and_then(|v| v.extract::<String>().ok())
                            .unwrap_or_default();
                        let curve = spec
                            .get_item("curve")
                            .ok()
                            .flatten()
                            .and_then(|v| v.extract::<String>().ok())
                            .unwrap_or_else(|| "linear".to_string());
                        let style = spec
                            .get_item("style")
                            .ok()
                            .flatten()
                            .and_then(|v| v.extract::<String>().ok())
                            .unwrap_or_else(|| "slider".to_string());
                        let options: Option<Vec<String>> = spec
                            .get_item("options")
                            .ok()
                            .flatten()
                            .and_then(|v| v.extract::<Vec<String>>().ok());
                        let display_name = Self::to_title_case(&name);
                        names.insert(i as u8, display_name.clone());
                        metadata.push(ParamMetadata {
                            name: display_name,
                            key: name,
                            min,
                            max,
                            default: default.clamp(min.min(max), min.max(max)),
                            unit,
                            curve,
                            style,
                            options,
                        });
                    }
                }
                if !metadata.is_empty() {
                    return (names, Some(metadata));
                }
            }
        }

        let param_names = match module.getattr("PARAM_NAMES") {
            Ok(attr) => {
                if let Ok(dict) = attr.downcast::<PyDict>() {
                    dict.iter()
                        .filter_map(|(k, v)| {
                            let addr = k.extract::<u8>().ok()?;
                            let name = v.extract::<String>().ok()?;
                            if (addr as usize) < PARAM_COUNT {
                                Some((addr, name))
                            } else {
                                None
                            }
                        })
                        .collect()
                } else {
                    HashMap::new()
                }
            }
            Err(_) => HashMap::new(),
        };
        let _ = py; // silence unused
        (param_names, None)
    }

    fn extract_telemetry(module: &Bound<'_, PyModule>) -> Option<Vec<TelemetryMetadata>> {
        let attr = module.getattr("TELEMETRY").ok()?;
        let dict = attr.downcast::<PyDict>().ok()?;
        let mut metadata = Vec::new();
        for (i, (key, val)) in dict.iter().enumerate() {
            if i >= TELEMETRY_LEN {
                break;
            }
            let key_str = match key.extract::<String>() {
                Ok(n) => n,
                Err(_) => continue,
            };
            let spec_dict = val.downcast::<PyDict>().ok();
            let unit = spec_dict
                .as_ref()
                .and_then(|spec| spec.get_item("unit").ok().flatten())
                .and_then(|v| v.extract::<String>().ok())
                .unwrap_or_default();
            let shape = spec_dict
                .as_ref()
                .and_then(|spec| spec.get_item("shape").ok().flatten())
                .and_then(|v| v.extract::<String>().ok())
                .unwrap_or_else(|| "scalar".to_string());
            metadata.push(TelemetryMetadata {
                name: key_str.clone(),
                key: key_str,
                unit,
                shape,
            });
        }
        if metadata.is_empty() {
            None
        } else {
            Some(metadata)
        }
    }

    /// Extract the script's `STATE = {…}` module-level dict, returning
    /// (json_string, declared_keys). Returns (None, []) when the script
    /// doesn't declare a STATE dict.
    fn extract_state_defaults(module: &Bound<'_, PyModule>) -> (Option<String>, Vec<String>) {
        let attr = match module.getattr("STATE") {
            Ok(a) => a,
            Err(_) => return (None, Vec::new()),
        };
        let dict = match attr.downcast::<PyDict>() {
            Ok(d) => d,
            Err(_) => return (None, Vec::new()),
        };
        // Order-preserving collection of keys (Python 3.7+ dict insertion
        // order is reliable). We use it to build the validator surface
        // and the "unknown persisted key" log line.
        let keys: Vec<String> = dict
            .iter()
            .filter_map(|(k, _)| k.extract::<String>().ok())
            .collect();
        // json.dumps(STATE) — using Python's json module for round-trip
        // fidelity (dates, NaNs, custom encoders are all out of scope but
        // simple dict-of-lists/dict/strings/numbers/bools work).
        let py = dict.py();
        let json_module = match py.import("json") {
            Ok(m) => m,
            Err(_) => return (None, keys),
        };
        let json_str = json_module
            .call_method1("dumps", (dict,))
            .ok()
            .and_then(|s| s.extract::<String>().ok());
        (json_str, keys)
    }

    fn to_title_case(s: &str) -> String {
        s.split('_')
            .filter(|w| !w.is_empty())
            .map(|word| {
                let mut chars = word.chars();
                match chars.next() {
                    None => String::new(),
                    Some(c) => {
                        let upper: String = c.to_uppercase().collect();
                        upper + &chars.as_str().to_lowercase()
                    }
                }
            })
            .collect::<Vec<_>>()
            .join(" ")
    }

    /// (Re)build the per-block ctx object — 2D numpy arrays sized to
    /// `(channel_count, max_frames)` (one per role), telemetry dict
    /// pre-seeded with declared slot keys. Called from `initialize()`
    /// and any time the channel count or max frames changes.
    fn allocate_py_arrays(&mut self, channel_count: usize, max_frames: usize) {
        if self.py_max_frames != max_frames {
            self.py_telemetry_dict = None;
        }
        self.py_max_frames = max_frames;
        let result = Python::with_gil(|py| -> PyResult<()> {
            // Set the cached `:` slice first — PySlice::full is infallible.
            // Anchoring it before any fallible setattr / import calls means
            // a partial-failure state never has the slice cache pointing
            // at None while leaving an interpreter-visible ctx object
            // around. The prefix slice rebuilds lazily on the first block
            // whose frame_count differs from cached_prefix_for_frames.
            self.cached_full_slice = Some(PySlice::full(py).unbind());
            self.cached_prefix_slice = None;
            self.cached_prefix_for_frames = u32::MAX;

            // Allocate 2D backing arrays of shape (channel_count, max_frames),
            // one per role. Scripts see them directly as ctx.inputs / outputs /
            // sidechain — no list wrapping. `ctx.inputs[ch]` returns a 1D row
            // view; `ctx.outputs[:] = ctx.inputs * gain` broadcasts across all
            // channels (per-row SIMD inside numpy). PyArray2::zeros allocates
            // row-major (C-contiguous) by default, so per-row slices are
            // contiguous.
            let input_array =
                PyArray2::<f32>::zeros(py, [channel_count, max_frames], false);
            let output_array =
                PyArray2::<f32>::zeros(py, [channel_count, max_frames], false);
            // Sidechain is always allocated and zero-filled when the host has
            // nothing routed, so scripts see a defined signal without having
            // to check for None.
            let sidechain_array =
                PyArray2::<f32>::zeros(py, [channel_count, max_frames], false);

            // Build the canonical ctx object. We use `types.SimpleNamespace`
            // for read-mostly attributes (transport, sample_rate,
            // frame_count, params, state) and direct attribute writes for
            // the audio arrays / telemetry dict that scripts are expected to
            // read.
            let types_module = py.import("types")?;
            let simple_ns_cls = types_module.getattr("SimpleNamespace")?;
            let ctx = simple_ns_cls.call0()?;

            ctx.setattr("inputs", &input_array)?;
            ctx.setattr("outputs", &output_array)?;
            ctx.setattr("sidechain", &sidechain_array)?;

            self.py_input_array = Some(input_array.unbind());
            self.py_output_array = Some(output_array.unbind());
            self.py_sidechain_array = Some(sidechain_array.unbind());

            // Transport: a SimpleNamespace with the canonical field names.
            // We rebuild the whole namespace each block (six attribute
            // writes — cheap) rather than caching one to set fields on,
            // because SimpleNamespace doesn't enforce read-only attrs and
            // we want the script's view to reflect *only* the current
            // block's transport. Initialize with sensible defaults here
            // so a script that reads ctx.transport.bpm before the host
            // pushes any transport sees 120 BPM, not garbage.
            let tport = simple_ns_cls.call0()?;
            tport.setattr("bpm", 120.0_f64)?;
            tport.setattr("beat", 0.0_f64)?;
            tport.setattr("is_playing", false)?;
            tport.setattr("time_sig_numerator", 4_i32)?;
            tport.setattr("time_sig_denominator", 4_i32)?;
            tport.setattr("sample_position", 0.0_f64)?;
            ctx.setattr("transport", tport)?;

            ctx.setattr("sample_rate", 44100.0_f64)?;
            ctx.setattr("frame_count", 0_u32)?;

            // Params: pre-seed with metadata keys (or empty for legacy
            // mode) so the first block's writes are dict updates, not
            // insertions. We expose this via `conjuredsp._ctx.ParamsView`
            // which supports both `ctx.params["name"]` and the more
            // discoverable `ctx.params.name` style. Cache the underlying
            // dict so the per-block update mutates in place — ParamsView
            // wraps the same dict by reference, so script reads see
            // updated values without us touching the wrapper.
            if let Some(ref metadata) = self.param_metadata {
                let dict = PyDict::new(py);
                for meta in metadata.iter() {
                    dict.set_item(&meta.key, meta.default)?;
                }
                let ctx_module = py.import("conjuredsp._ctx")?;
                let params_view_cls = ctx_module.getattr("ParamsView")?;
                let view = params_view_cls.call1((dict.clone(),))?;
                ctx.setattr("params", view)?;
                self.py_params_dict = Some(dict.into_any().unbind());
            } else {
                self.py_params_dict = None;
                let list = PyList::new(py, [0.0f32; PARAM_COUNT].iter())?;
                ctx.setattr("params", list)?;
            }

            // Telemetry: a writable dict pre-seeded with declared slot
            // keys. Vector slots get a numpy array sized to MAX_FRAMES
            // (mirrors the legacy semantics — scripts write
            // `ctx.telemetry["scope"][:n] = …`).
            let telemetry_dict = PyDict::new(py);
            if let Some(ref meta) = self.telemetry_metadata {
                for slot in meta {
                    if slot.is_vector() {
                        let arr = PyArray1::<f32>::zeros(py, self.py_max_frames, false);
                        telemetry_dict.set_item(&slot.key, arr)?;
                    } else {
                        telemetry_dict.set_item(&slot.key, 0.0_f32)?;
                    }
                }
            }
            ctx.setattr("telemetry", &telemetry_dict)?;
            self.py_telemetry_dict = Some(telemetry_dict.into_any().unbind());

            // State: starts as MappingProxyType over an empty dict.
            // Replaced on first call to `update_state_view` (which the
            // process loop always calls before invoking process()).
            let empty = PyDict::new(py);
            let mappingproxy = py.import("types")?.getattr("MappingProxyType")?;
            let proxy = mappingproxy.call1((empty,))?;
            ctx.setattr("state", proxy)?;

            self.py_ctx = Some(ctx.unbind());
            Ok(())
        });
        if let Err(e) = result {
            let msg = Python::with_gil(|py| {
                format!("PythonBackend::allocate_py_arrays failed: {}", e.value(py))
            });
            eprintln!("ConjureDSP-Rust: {}", msg);
            self.last_error = Some(msg);
        }
        // ctx.state was just rebuilt to an empty MappingProxyType; force
        // the next update_state_view to re-parse rather than skip on a
        // generation-match against the kernel's pre-rebuild value.
        self.py_state_gen = u64::MAX;
    }

    /// Update `ctx.state` if the kernel's state generation has changed
    /// since the last block. In the steady state this is one Python
    /// `setattr` skip — no dict creation, no JSON parse.
    fn update_state_view(
        &mut self,
        py: Python<'_>,
        state: &StateSnapshot,
    ) -> PyResult<()> {
        if state.generation == self.py_state_gen {
            return Ok(());
        }
        // Parse the JSON byte buffer into a Python dict (json.loads
        // round-trip — same approach as `extract_state_defaults`). On
        // parse error fall back to an empty dict; the script will see
        // missing keys and the kernel will fall through to passthrough
        // when it raises.
        let json_module = py.import("json")?;
        let bytes_view = pyo3::types::PyBytes::new(py, state.bytes.as_ref());
        let parsed = json_module
            .call_method1("loads", (bytes_view,))
            .or_else(|_| -> PyResult<Bound<'_, PyAny>> {
                Ok(PyDict::new(py).into_any())
            })?;
        // If the parsed value isn't a dict (e.g. a script writes a list
        // as the top-level state), wrap it in a single-key dict so
        // ctx.state's mapping interface stays consistent. Real usage
        // always has dict-shaped state.
        let dict_value: Bound<'_, PyAny> = if parsed.downcast::<PyDict>().is_ok() {
            parsed
        } else {
            let d = PyDict::new(py);
            d.set_item("_root", parsed)?;
            d.into_any()
        };
        let mappingproxy = py.import("types")?.getattr("MappingProxyType")?;
        let proxy = mappingproxy.call1((dict_value,))?;
        if let Some(ref ctx_handle) = self.py_ctx {
            ctx_handle.bind(py).setattr("state", proxy)?;
        }
        self.py_state_gen = state.generation;
        Ok(())
    }

    /// Delegate audio processing to the loaded Python script.
    /// Returns true on success.
    unsafe fn process_with_python(
        &mut self,
        inputs: &[*const f32],
        outputs: &[*mut f32],
        channel_count: usize,
        frame_count: usize,
        sample_rate: f64,
        params: &[f32; PARAM_COUNT],
        transport: &TransportState,
        sidechain: SidechainInput<'_>,
        state: &StateSnapshot,
    ) -> bool {
        let result: Result<(), PyErr> = Python::with_gil(|py| {
            // Refresh state view (no-op when generation hasn't moved).
            self.update_state_view(py, state)?;

            let ctx_handle = match self.py_ctx {
                Some(ref c) => c.bind(py),
                None => {
                    return Err(pyo3::exceptions::PyRuntimeError::new_err(
                        "PythonBackend: ctx not initialized",
                    ));
                }
            };

            // Copy input audio into pre-allocated 2D numpy array. One bind
            // + one as_array_mut per role per block, then per-channel row
            // copies via as_slice_mut on each row view (rows of a
            // C-contiguous PyArray2 are contiguous by construction).
            {
                let in_array = self
                    .py_input_array
                    .as_ref()
                    .ok_or_else(|| pyo3::exceptions::PyRuntimeError::new_err(
                        "PythonBackend: input array not allocated",
                    ))?
                    .bind(py);
                let mut in_view = in_array.as_array_mut();
                for ch in 0..channel_count {
                    let src = std::slice::from_raw_parts(inputs[ch], frame_count);
                    let mut row = in_view.row_mut(ch);
                    let row_slice = row
                        .as_slice_mut()
                        .expect("row of C-contiguous PyArray2 must be contiguous");
                    row_slice[..frame_count].copy_from_slice(src);
                }
            }

            // Refresh sidechain numpy array. Always overwrite the full
            // window so scripts see a defined signal even after a
            // host-disconnect.
            {
                let sc_array = self
                    .py_sidechain_array
                    .as_ref()
                    .ok_or_else(|| pyo3::exceptions::PyRuntimeError::new_err(
                        "PythonBackend: sidechain array not allocated",
                    ))?
                    .bind(py);
                let mut sc_view = sc_array.as_array_mut();
                for ch in 0..channel_count {
                    let mut row = sc_view.row_mut(ch);
                    let row_slice = row
                        .as_slice_mut()
                        .expect("row of C-contiguous PyArray2 must be contiguous");
                    let dst = &mut row_slice[..frame_count];
                    if sidechain.connected && ch < sidechain.channel_count {
                        let src = std::slice::from_raw_parts(sidechain.inputs[ch], frame_count);
                        dst.copy_from_slice(src);
                    } else {
                        for v in dst.iter_mut() {
                            *v = 0.0;
                        }
                    }
                }
            }

            // Update params (denormalize via metadata when present).
            if let Some(ref metadata) = self.param_metadata {
                // Mutate the cached dict in place. The `ParamsView`
                // already on `ctx.params` shares this dict by Python ref,
                // so script reads see updated values without us
                // allocating a fresh dict + view each block.
                let dict_handle = self
                    .py_params_dict
                    .as_ref()
                    .ok_or_else(|| pyo3::exceptions::PyRuntimeError::new_err(
                        "PythonBackend: params dict not initialized",
                    ))?;
                let dict = dict_handle.bind(py).downcast::<PyDict>()?;
                for (i, meta) in metadata.iter().enumerate() {
                    let actual = meta.denormalize(params[i]);
                    dict.set_item(&meta.key, actual)?;
                }
            } else {
                let params_attr = ctx_handle.getattr("params")?;
                let list = params_attr.downcast::<PyList>()?;
                for (i, &val) in params.iter().enumerate() {
                    list.set_item(i, val)?;
                }
            }

            // Update transport (always rebuild the namespace — six
            // attribute writes is cheaper than caching + comparing).
            let tport = ctx_handle.getattr("transport")?;
            tport.setattr("bpm", transport.bpm)?;
            tport.setattr("beat", transport.beat)?;
            tport.setattr("is_playing", transport.is_playing)?;
            tport.setattr("time_sig_numerator", transport.time_sig_numerator)?;
            tport.setattr("time_sig_denominator", transport.time_sig_denominator)?;
            tport.setattr("sample_position", transport.sample_position)?;

            ctx_handle.setattr("sample_rate", sample_rate)?;
            ctx_handle.setattr("frame_count", frame_count as u32)?;

            // Replace ctx.inputs / outputs / sidechain with views sliced to
            // [:, :frame_count]. The backing arrays stay alive via
            // self.py_*_array; the views remain valid for the duration of
            // process(). Whole-array operations on the views are implicitly
            // windowed to frame_count (np.tanh(ctx.inputs, out=ctx.outputs),
            // ctx.outputs[:] = ctx.inputs * gain), so nothing leaks into the
            // slack region. Out-of-bounds writes like ctx.outputs[ch][N]
            // (N >= frame_count) raise IndexError on a sliced view, surfacing
            // bugs that would have silently corrupted the next block under
            // the unsliced shape.
            //
            // The prefix slice is rebuilt only when frame_count changes; the
            // common case (DAW with stable buffer size) reuses the cached
            // slice across blocks for zero per-block allocation.
            if self.cached_prefix_for_frames != frame_count as u32 {
                let p = PySlice::new(py, 0, frame_count as isize, 1);
                self.cached_prefix_slice = Some(p.unbind());
                self.cached_prefix_for_frames = frame_count as u32;
            }
            {
                let full = self
                    .cached_full_slice
                    .as_ref()
                    .ok_or_else(|| pyo3::exceptions::PyRuntimeError::new_err(
                        "PythonBackend: full slice not cached",
                    ))?
                    .bind(py);
                let prefix = self
                    .cached_prefix_slice
                    .as_ref()
                    .ok_or_else(|| pyo3::exceptions::PyRuntimeError::new_err(
                        "PythonBackend: prefix slice not cached",
                    ))?
                    .bind(py);
                let in_array = self.py_input_array.as_ref().unwrap().bind(py);
                let out_array = self.py_output_array.as_ref().unwrap().bind(py);
                let sc_array = self.py_sidechain_array.as_ref().unwrap().bind(py);
                let in_view = in_array.get_item((full, prefix))?;
                let out_view = out_array.get_item((full, prefix))?;
                let sc_view = sc_array.get_item((full, prefix))?;
                ctx_handle.setattr("inputs", in_view)?;
                ctx_handle.setattr("outputs", out_view)?;
                ctx_handle.setattr("sidechain", sc_view)?;
            }

            // Single ctx call. The script sees the sliced views; Rust's
            // output copy below reads from the unsliced backing array.
            self.py_process_fn.call1(py, (ctx_handle,))?;

            // Snapshot telemetry back into the f32 buffer the kernel reads.
            if let Some(ref meta) = self.telemetry_metadata {
                if let Some(ref dict_handle) = self.py_telemetry_dict {
                    let dict = dict_handle.bind(py).downcast::<PyDict>()?;
                    for (i, slot) in meta.iter().enumerate() {
                        if i >= TELEMETRY_LEN {
                            break;
                        }
                        if slot.is_vector() {
                            continue;
                        }
                        if let Ok(Some(val)) = dict.get_item(&slot.key) {
                            if let Ok(v) = val.extract::<f32>() {
                                self.telemetry_buf[i] = v;
                            }
                        }
                    }
                }
            }

            // Copy output back to audio buffers. Single bind + as_array on
            // the 2D backing array, then per-channel row reads.
            {
                let out_array = self
                    .py_output_array
                    .as_ref()
                    .ok_or_else(|| pyo3::exceptions::PyRuntimeError::new_err(
                        "PythonBackend: output array not allocated",
                    ))?
                    .bind(py);
                let out_view = out_array.as_array();
                for ch in 0..channel_count {
                    let dst = std::slice::from_raw_parts_mut(outputs[ch], frame_count);
                    let row = out_view.row(ch);
                    let row_slice = row
                        .as_slice()
                        .expect("row of C-contiguous PyArray2 must be contiguous");
                    dst.copy_from_slice(&row_slice[..frame_count]);
                }
            }

            Ok(())
        });

        match result {
            Ok(()) => true,
            Err(e) => {
                let err_msg = Python::with_gil(|py| {
                    let tb_str = e
                        .traceback(py)
                        .and_then(|tb| tb.format().ok())
                        .unwrap_or_default();
                    let msg = format!("Python process error: {}", e.value(py));
                    e.print(py);
                    if tb_str.is_empty() {
                        msg
                    } else {
                        format!("{}{}", tb_str, msg)
                    }
                });
                self.last_error = Some(err_msg);
                false
            }
        }
    }
}

impl Backend for PythonBackend {
    fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
        self
    }

    fn initialize(&mut self, channel_count: usize, _sample_rate: f64, max_frames: u32) {
        self.allocate_py_arrays(channel_count, max_frames as usize);
    }

    fn deinitialize(&mut self) {
        if self.py_input_array.is_some() {
            Python::with_gil(|_py| {
                self.py_input_array = None;
                self.py_output_array = None;
                self.py_sidechain_array = None;
                self.py_telemetry_dict = None;
                self.py_state_dict = None;
                self.py_ctx = None;
            });
        }
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
        state: &StateSnapshot,
    ) -> bool {
        if self.py_input_array.is_none() {
            self.last_error = Some(
                "Python arrays not allocated — initialize() not called or failed".to_string(),
            );
            return false;
        }
        self.process_with_python(
            inputs,
            outputs,
            channel_count,
            frame_count,
            sample_rate,
            params,
            transport,
            sidechain,
            state,
        )
    }

    fn last_error(&self) -> Option<&str> {
        self.last_error.as_deref()
    }

    fn clear_last_error(&mut self) {
        self.last_error = None;
    }

    fn param_names(&self) -> HashMap<u8, String> {
        self.param_names.clone()
    }

    fn param_metadata(&self) -> Option<&[ParamMetadata]> {
        self.param_metadata.as_deref()
    }

    fn latency_samples(&self) -> u32 {
        self.latency_samples
    }

    fn telemetry_metadata(&self) -> Option<&[TelemetryMetadata]> {
        self.telemetry_metadata.as_deref()
    }

    fn state_defaults_json(&self) -> Option<&str> {
        self.state_defaults_json.as_deref()
    }

    fn state_max_bytes(&self) -> Option<usize> {
        self.state_max_bytes
    }

    fn read_telemetry(&self, out: &mut [f32; TELEMETRY_LEN]) {
        if self.telemetry_metadata.is_none() {
            return;
        }
        out.copy_from_slice(&self.telemetry_buf);
    }

    fn read_telemetry_vec(
        &self,
        slot_index: usize,
        frame_count: usize,
        out: &mut [f32],
    ) {
        let meta = match &self.telemetry_metadata {
            Some(m) => m,
            None => return,
        };
        let spec = match meta.get(slot_index) {
            Some(s) if s.is_vector() => s,
            _ => return,
        };
        let dict_handle = match &self.py_telemetry_dict {
            Some(d) => d,
            None => return,
        };
        let n = frame_count.min(out.len()).min(self.py_max_frames);
        if n == 0 {
            return;
        }
        let _ = Python::with_gil(|py| -> Result<(), pyo3::PyErr> {
            let dict = dict_handle.bind(py);
            let val = match dict
                .downcast::<PyDict>()
                .ok()
                .and_then(|d| d.get_item(&spec.key).ok().flatten())
            {
                Some(v) => v,
                None => return Ok(()),
            };
            let arr: &Bound<'_, PyArray1<f32>> = match val.downcast::<PyArray1<f32>>() {
                Ok(a) => a,
                Err(_) => return Ok(()),
            };
            let slice = unsafe { arr.as_slice() }?;
            let copy_len = n.min(slice.len());
            out[..copy_len].copy_from_slice(&slice[..copy_len]);
            Ok(())
        });
    }
}
