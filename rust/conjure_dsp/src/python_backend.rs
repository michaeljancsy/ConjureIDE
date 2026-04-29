use crate::backend::Backend;
use crate::kernel::TransportState;
use crate::params::{ParamMetadata, TelemetryMetadata, PARAM_COUNT, TELEMETRY_LEN};
use numpy::{PyArray1, PyArrayMethods};
use pyo3::prelude::*;
use pyo3::types::{PyDict, PyList};
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
/// Loads a Python script containing a
/// `process(inputs, outputs, frame_count, sample_rate, params, transport, telemetry)`
/// function (canonical 7-arg form) and calls it each render callback
/// with pre-allocated numpy arrays. Scripts with anything other than
/// exactly 7 args are rejected at load time — use `_transport` /
/// `_telemetry` (Python's underscore-prefix convention for unused
/// args) when you don't read them.
pub struct PythonBackend {
    py_process_fn: Py<PyAny>,
    py_input_arrays: Vec<Py<PyAny>>,
    py_output_arrays: Vec<Py<PyAny>>,
    py_channel_count: usize,
    last_error: Option<String>,
    param_names: HashMap<u8, String>,
    /// Rich parameter metadata from `PARAMS` dict. When present, process()
    /// passes a dict of denormalized values instead of a list of 0–1 floats.
    param_metadata: Option<Vec<ParamMetadata>>,
    /// Script-declared telemetry slot metadata (from `TELEMETRY` dict).
    /// `None` when the script doesn't declare one — matches the missing-
    /// metadata-export semantics in the WASM backend.
    telemetry_metadata: Option<Vec<TelemetryMetadata>>,
    /// Cached PyDict for telemetry slots (created once, values updated
    /// in-place each block). Pre-seeded with `0.0` for each declared
    /// slot so script `telemetry["x"] = …` writes are dict updates,
    /// not key creations.
    py_telemetry_dict: Option<Py<PyAny>>,
    /// Per-block telemetry snapshot the kernel reads via `read_telemetry`.
    /// Filled by `process_with_python` after the script returns; values
    /// are addressed by the metadata index, in declaration order.
    telemetry_buf: [f32; TELEMETRY_LEN],
    /// Max frames the host may pass to `process()` — used to size the
    /// per-vector-slot numpy arrays we pre-seed in the telemetry dict so
    /// scripts can write full per-frame buffers in-place without
    /// per-block reallocation.
    py_max_frames: usize,
    /// Script-declared algorithmic latency in samples (from `LATENCY` constant).
    latency_samples: u32,
    /// Cached PyList wrapping py_input_arrays (rebuilt on channel count change).
    py_input_list: Option<Py<PyAny>>,
    /// Cached PyList wrapping py_output_arrays (rebuilt on channel count change).
    py_output_list: Option<Py<PyAny>>,
    /// Cached PyDict for transport state (created once, values updated in-place).
    py_transport_dict: Option<Py<PyAny>>,
    /// Cached PyDict for params when using rich metadata (created once, values updated in-place).
    py_params_dict: Option<Py<PyAny>>,
    /// Cached PyList for params in legacy mode (no metadata). Created once, values updated in-place
    /// each callback to avoid per-callback allocation of 16 Python float objects + list.
    py_params_list: Option<Py<PyAny>>,
    /// Unique module name in sys.modules for this instance (e.g., "dsp_script_0").
    /// Stored so Drop can remove it from sys.modules to prevent memory leaks.
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
    /// Idempotent — skips if the path is already present.
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

    /// Load a Python script containing a `process()` function.
    /// `python_home` sets PYTHONHOME before interpreter init.
    pub fn load(python_home: &str, script_path: &str) -> Result<Self, String> {
        eprintln!(
            "ConjureDSP-Rust: PythonBackend::load called, python_home={}, script_path={}",
            python_home, script_path
        );

        // Set PYTHONHOME and PYTHONDONTWRITEBYTECODE exactly once. POSIX setenv()
        // is not thread-safe, and concurrent AU instance creation (e.g., DAW track
        // duplication) can corrupt the environment table. These values are always
        // the same across instances, so set-once is correct.
        let python_home_owned = python_home.to_string();
        PYTHON_ENV_INIT.get_or_init(|| {
            std::env::set_var("PYTHONHOME", &python_home_owned);
            std::env::set_var("PYTHONDONTWRITEBYTECODE", "1");
        });

        let result: Result<(Py<PyAny>, HashMap<u8, String>, Option<Vec<ParamMetadata>>, Option<Vec<TelemetryMetadata>>, u32, String), PyErr> =
            Python::with_gil(|py| {
                let code = std::fs::read_to_string(script_path)
                    .map_err(|e| pyo3::exceptions::PyIOError::new_err(e.to_string()))?;

                let code_c = CString::new(code)
                    .map_err(|e| pyo3::exceptions::PyValueError::new_err(e.to_string()))?;
                let path_c = CString::new(script_path)
                    .map_err(|e| pyo3::exceptions::PyValueError::new_err(e.to_string()))?;

                // Each backend instance gets a unique module name so multiple AU
                // instances in the same DAW process don't collide in sys.modules.
                let instance_id = INSTANCE_COUNTER.fetch_add(1, Ordering::Relaxed);
                let mod_name_str = format!("dsp_script_{}", instance_id);
                let module_name = CString::new(mod_name_str.as_str())
                    .map_err(|e| pyo3::exceptions::PyValueError::new_err(e.to_string()))?;

                // Remove any cached module so from_code creates a fresh one.
                // This handles the reload case where the same instance ID slot
                // is reused (e.g., hot-reload within a single AU instance).
                let sys = py.import("sys")?;
                let sys_modules = sys.getattr("modules")?;
                let _ = sys_modules.call_method1("pop", (mod_name_str.as_str(), py.None()));

                let module = PyModule::from_code(py, &code_c, &path_c, &module_name)?;
                let process_fn = module.getattr("process")?;

                // Require the canonical 7-arg signature. We pass all seven
                // args every render block; a function declaring fewer would
                // raise TypeError at call time, which is much more confusing
                // than a clear load-time error pointing at the convention.
                let arity: usize = process_fn
                    .getattr("__code__")?
                    .getattr("co_argcount")?
                    .extract()?;
                if arity != 7 {
                    return Err(pyo3::exceptions::PyTypeError::new_err(format!(
                        "process() must take exactly 7 arguments \
                        (inputs, outputs, frame_count, sample_rate, params, \
                        transport, telemetry); got {} args. Use _transport \
                        and _telemetry as parameter names if you don't \
                        read them.",
                        arity
                    )));
                }

                // Try PARAMS dict first (rich metadata):
                //   PARAMS = {"threshold": {"min": -40, "max": -3, "unit": "dB", "default": -20}, ...}
                let (param_names, param_metadata) =
                    Self::extract_params(py, &module);

                // Extract optional TELEMETRY dict for the DSP→UI scalar
                // channel. Same shape as PARAMS but a smaller schema:
                //   TELEMETRY = {"env": {"unit": ""}, "gr_db": {"unit": "dB"}}
                let telemetry_metadata = Self::extract_telemetry(&module);

                // Extract optional LATENCY constant (algorithmic latency in samples)
                let latency: u32 = module
                    .getattr("LATENCY")
                    .ok()
                    .and_then(|v| v.extract::<u32>().ok())
                    .unwrap_or(0);

                Ok((process_fn.unbind(), param_names, param_metadata, telemetry_metadata, latency, mod_name_str))
            });

        match result {
            Ok((process_fn, param_names, param_metadata, telemetry_metadata, latency, module_name)) => {
                eprintln!("ConjureDSP-Rust: Python script loaded successfully (latency={})", latency);
                Ok(Self {
                    py_process_fn: process_fn,
                    py_input_arrays: Vec::new(),
                    py_output_arrays: Vec::new(),
                    py_channel_count: 0,
                    last_error: None,
                    param_names,
                    param_metadata,
                    telemetry_metadata,
                    py_telemetry_dict: None,
                    telemetry_buf: [0.0; TELEMETRY_LEN],
                    py_max_frames: 0,
                    latency_samples: latency,
                    py_input_list: None,
                    py_output_list: None,
                    py_transport_dict: None,
                    py_params_dict: None,
                    py_params_list: None,
                    module_name,
                })
            }
            Err(e) => {
                let py_err_msg = Python::with_gil(|py| {
                    // Format traceback to include line numbers for the error parser
                    let tb_str = e.traceback(py)
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

    /// Extract parameter metadata from the Python module.
    /// Tries `PARAMS` dict first (rich metadata), falls back to `PARAM_NAMES` (names only).
    fn extract_params(
        py: Python<'_>,
        module: &Bound<'_, PyModule>,
    ) -> (HashMap<u8, String>, Option<Vec<ParamMetadata>>) {
        // Try PARAMS dict first: {"threshold": {"min": -40, "max": -3, "unit": "dB", "default": -20}}
        if let Ok(attr) = module.getattr("PARAMS") {
            if let Ok(dict) = attr.downcast::<PyDict>() {
                let mut metadata = Vec::new();
                let mut names = HashMap::new();
                // Python 3.7+ dicts preserve insertion order
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
                        // Title-case the name for display, keep original as key
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

        // Fall back to PARAM_NAMES dict: {0: "Cutoff", 1: "Resonance"}
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

        (param_names, None)
    }

    /// Extract the optional `TELEMETRY` dict from the loaded module.
    /// Schema mirrors PARAMS but smaller — just `{name: {unit?: str}}`.
    /// Returns `None` when the script doesn't declare one (the common
    /// case for legacy scripts), so the kernel skips the per-block
    /// snapshot read entirely.
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
            // Per-slot dict is optional — `{"x": {}}` is fine, no unit.
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
            // Pass-through naming: the JS-facing key is the dict key
            // verbatim. Differs from PARAMS, which title-cases for the
            // DAW display label — telemetry has no DAW surface so the
            // canonicalization would only mangle acronyms (DB / RMS /
            // GR / FFT). UIs that target both Rust and Python presets
            // read both forms via the `??` chain (the Rust side emits
            // SCREAMING_SNAKE; the Python side emits whatever the
            // dict key is, conventionally snake_case).
            metadata.push(TelemetryMetadata {
                name: key_str.clone(),
                key: key_str,
                unit,
                shape,
            });
        }
        if metadata.is_empty() { None } else { Some(metadata) }
    }

    /// Convert snake_case or lowercase name to Title Case for display.
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

    /// Allocate numpy arrays for the given channel count, sized to max_frames.
    /// Also pre-builds cached PyList/PyDict objects to avoid per-callback allocations.
    fn allocate_py_arrays(&mut self, channel_count: usize, max_frames: usize) {
        // Track max_frames for vector-telemetry numpy array sizing. Drop
        // any cached telemetry dict when the size changes so the next
        // build re-seeds vector slots with arrays of the correct length.
        if self.py_max_frames != max_frames {
            self.py_telemetry_dict = None;
        }
        self.py_max_frames = max_frames;
        Python::with_gil(|py| {
            self.py_input_arrays = (0..channel_count)
                .map(|_| {
                    PyArray1::<f32>::zeros(py, max_frames, false)
                        .into_any()
                        .unbind()
                })
                .collect();

            self.py_output_arrays = (0..channel_count)
                .map(|_| {
                    PyArray1::<f32>::zeros(py, max_frames, false)
                        .into_any()
                        .unbind()
                })
                .collect();

            // Cache PyLists wrapping the numpy arrays (stable across callbacks)
            if let Ok(list) =
                PyList::new(py, self.py_input_arrays.iter().map(|a| a.bind(py)))
            {
                self.py_input_list = Some(list.into_any().unbind());
            }
            if let Ok(list) =
                PyList::new(py, self.py_output_arrays.iter().map(|a| a.bind(py)))
            {
                self.py_output_list = Some(list.into_any().unbind());
            }

            // Cache transport dict (keys are stable, values updated in-place each callback)
            let dict = PyDict::new(py);
            let _ = dict.set_item("tempo", 120.0f64);
            let _ = dict.set_item("beat", 0.0f64);
            let _ = dict.set_item("playing", false);
            let _ = dict.set_item("time_sig_num", 4.0f64);
            let _ = dict.set_item("time_sig_den", 4.0f64);
            let _ = dict.set_item("sample_pos", 0.0f64);
            self.py_transport_dict = Some(dict.into_any().unbind());

            // Cache params dict (keys are stable, values updated in-place each callback)
            if let Some(ref metadata) = self.param_metadata {
                let dict = PyDict::new(py);
                for meta in metadata.iter() {
                    let _ = dict.set_item(&meta.key, meta.default);
                }
                self.py_params_dict = Some(dict.into_any().unbind());
            } else {
                // Cache legacy params list (16 zeros, values updated in-place each callback)
                if let Ok(list) = PyList::new(py, [0.0f32; PARAM_COUNT].iter()) {
                    self.py_params_list = Some(list.into_any().unbind());
                }
            }
        });
        self.py_channel_count = channel_count;
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
    ) -> bool {
        let result: Result<(), PyErr> = Python::with_gil(|py| {
            // Copy input audio data into pre-allocated numpy arrays
            for ch in 0..channel_count {
                let src = std::slice::from_raw_parts(inputs[ch], frame_count);
                let py_arr: &Bound<'_, PyArray1<f32>> =
                    self.py_input_arrays[ch].bind(py).downcast()?;
                let py_slice = py_arr.as_slice_mut()?;
                py_slice[..frame_count].copy_from_slice(src);
            }

            // Use cached Python lists (rebuilt only on channel count change)
            let input_list = match self.py_input_list {
                Some(ref cached) => cached.bind(py).clone(),
                None => PyList::new(py, self.py_input_arrays.iter().map(|a| a.bind(py)))?.into_any(),
            };
            let output_list = match self.py_output_list {
                Some(ref cached) => cached.bind(py).clone(),
                None => PyList::new(py, self.py_output_arrays.iter().map(|a| a.bind(py)))?.into_any(),
            };

            // Update params: use cached dict (update values in-place) or create list for legacy mode
            let params_obj: Bound<'_, PyAny> = if let Some(ref metadata) = self.param_metadata {
                if let Some(ref cached) = self.py_params_dict {
                    let dict = cached.bind(py);
                    for (i, meta) in metadata.iter().enumerate() {
                        let actual = meta.denormalize(params[i]);
                        dict.set_item(&meta.key, actual)?;
                    }
                    dict.clone()
                } else {
                    let dict = PyDict::new(py);
                    for (i, meta) in metadata.iter().enumerate() {
                        let actual = meta.denormalize(params[i]);
                        dict.set_item(&meta.key, actual)?;
                    }
                    dict.into_any()
                }
            } else if let Some(ref cached) = self.py_params_list {
                let list = cached.bind(py);
                for (i, &val) in params.iter().enumerate() {
                    list.set_item(i, val)?;
                }
                list.clone()
            } else {
                PyList::new(py, params.iter())?.into_any()
            };

            // Update the cached transport dict in place. Allocated by
            // allocate_render_resources; should always be present here.
            let transport_obj: Bound<'_, PyAny> = if let Some(ref cached) = self.py_transport_dict {
                let dict = cached.bind(py);
                dict.set_item("tempo", transport.tempo)?;
                dict.set_item("beat", transport.beat_position)?;
                dict.set_item("playing", transport.is_playing)?;
                dict.set_item("time_sig_num", transport.time_sig_numerator)?;
                dict.set_item("time_sig_den", transport.time_sig_denominator)?;
                dict.set_item("sample_pos", transport.sample_position)?;
                dict.clone()
            } else {
                let dict = PyDict::new(py);
                dict.set_item("tempo", transport.tempo)?;
                dict.set_item("beat", transport.beat_position)?;
                dict.set_item("playing", transport.is_playing)?;
                dict.set_item("time_sig_num", transport.time_sig_numerator)?;
                dict.set_item("time_sig_den", transport.time_sig_denominator)?;
                dict.set_item("sample_pos", transport.sample_position)?;
                dict.into_any()
            };

            // Telemetry dict pre-seeded with declared-slot keys at zero so
            // the script's `telemetry["x"] = …` writes are dict updates,
            // never key insertions. Cached on first build to avoid
            // per-block PyDict allocation on the hot path.
            let telemetry_obj: Bound<'_, PyAny> = if let Some(ref cached) = self.py_telemetry_dict {
                cached.bind(py).clone()
            } else {
                let new_dict = PyDict::new(py);
                if let Some(ref meta) = self.telemetry_metadata {
                    for slot in meta {
                        if slot.is_vector() {
                            // Vector slots get a pre-allocated numpy
                            // array sized to MAX_FRAMES so scripts can
                            // write per-frame samples in place
                            // (`telemetry["scope"][:n] = …`) without
                            // per-block allocation. Length stays fixed
                            // across blocks; the kernel uses the live
                            // `frame_count` to truncate on read.
                            let arr = PyArray1::<f32>::zeros(py, self.py_max_frames, false);
                            new_dict.set_item(&slot.key, arr)?;
                        } else {
                            new_dict.set_item(&slot.key, 0.0_f32)?;
                        }
                    }
                }
                let any = new_dict.into_any();
                self.py_telemetry_dict = Some(any.clone().unbind());
                any
            };

            // Canonical 7-arg call. Anything else was rejected at load
            // time (see PythonBackend::load).
            self.py_process_fn.call1(
                py,
                (
                    input_list, output_list, frame_count as u32, sample_rate,
                    params_obj,
                    &transport_obj,
                    &telemetry_obj,
                ),
            )?;

            // Snapshot the telemetry dict back into the f32 buffer the
            // kernel reads via `read_telemetry`. Slots without a numeric
            // entry stay at the previous block's value — that's
            // acceptable for a meter (a missed update reads as "no
            // change") and keeps the hot path branch-free.
            //
            // Split the borrow manually: we hold &mut self.telemetry_buf
            // while iterating &self.telemetry_metadata. Pull metadata out
            // first via a raw pointer dance? No — easier to just buffer
            // the keys upfront. Since the metadata vec is set at load
            // time and never mutated during process(), a quick clone of
            // the keys is acceptable; this path runs only when telemetry
            // is in use, and the slot count is ≤8.
            if let Some(ref meta) = self.telemetry_metadata {
                let dict = telemetry_obj.downcast::<PyDict>()?;
                for (i, slot) in meta.iter().enumerate() {
                    if i >= TELEMETRY_LEN { break; }
                    // Vector slots write directly into the cached numpy
                    // array — no scalar copy-out. The kernel calls
                    // `read_telemetry_vec` to drain those.
                    if slot.is_vector() { continue; }
                    if let Ok(Some(val)) = dict.get_item(&slot.key) {
                        if let Ok(v) = val.extract::<f32>() {
                            self.telemetry_buf[i] = v;
                        }
                    }
                }
            }

            // Copy output from pre-allocated numpy arrays back to audio buffers
            for ch in 0..channel_count {
                let dst = std::slice::from_raw_parts_mut(outputs[ch], frame_count);
                let py_arr: &Bound<'_, PyArray1<f32>> =
                    self.py_output_arrays[ch].bind(py).downcast()?;
                let py_slice = py_arr.as_slice()?;
                dst.copy_from_slice(&py_slice[..frame_count]);
            }

            Ok(())
        });

        match result {
            Ok(()) => true,
            Err(e) => {
                let err_msg = Python::with_gil(|py| {
                    let tb_str = e.traceback(py)
                        .and_then(|tb| tb.format().ok())
                        .unwrap_or_default();
                    let msg = format!("Python process error: {}", e.value(py));
                    e.print(py);
                    if tb_str.is_empty() { msg } else { format!("{}{}", tb_str, msg) }
                });
                self.last_error = Some(err_msg);
                false
            }
        }
    }
}

impl Backend for PythonBackend {
    fn as_any_mut(&mut self) -> &mut dyn std::any::Any { self }

    fn initialize(&mut self, channel_count: usize, _sample_rate: f64, max_frames: u32) {
        self.allocate_py_arrays(channel_count, max_frames as usize);
    }

    fn deinitialize(&mut self) {
        if !self.py_input_arrays.is_empty() {
            Python::with_gil(|_py| {
                self.py_input_arrays.clear();
                self.py_output_arrays.clear();
                self.py_input_list = None;
                self.py_output_list = None;
                self.py_transport_dict = None;
                self.py_params_dict = None;
                self.py_params_list = None;
                self.py_telemetry_dict = None;
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
    ) -> bool {
        if self.py_input_arrays.is_empty() {
            self.last_error = Some("Python arrays not allocated — initialize() not called or failed".to_string());
            return false;
        }
        self.process_with_python(inputs, outputs, channel_count, frame_count, sample_rate, params, transport)
    }

    fn last_error(&self) -> Option<&str> {
        self.last_error.as_deref()
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
        // Validate slot is declared and shape=vector before going
        // through the GIL. Saves a few hundred ns per scalar slot per
        // block in the kernel's harvest loop.
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
        // Acquiring the GIL on the audio thread is a known cost we
        // already pay every block in `process_with_python`. Doing it
        // again here adds ~1 µs per declared vector slot — well within
        // the budget for typical 1–4 vector slots.
        let _ = Python::with_gil(|py| -> Result<(), pyo3::PyErr> {
            let dict = dict_handle.bind(py);
            let val = match dict.downcast::<PyDict>().ok().and_then(|d|
                d.get_item(&spec.key).ok().flatten())
            {
                Some(v) => v,
                None => return Ok(()),
            };
            // The script may have rebound the slot to a non-numpy value;
            // tolerate that gracefully (silent no-op).
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
