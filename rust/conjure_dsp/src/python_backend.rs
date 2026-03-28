use crate::backend::Backend;
use crate::kernel::TransportState;
use crate::params::{ParamMetadata, PARAM_COUNT};
use numpy::{PyArray1, PyArrayMethods};
use pyo3::prelude::*;
use pyo3::types::{PyDict, PyList};
use std::collections::HashMap;
use std::ffi::CString;

/// Python DSP backend using pyo3 and numpy.
///
/// Loads a Python script containing a `process(inputs, outputs, frame_count, sample_rate)`
/// function and calls it each render callback with pre-allocated numpy arrays.
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
    /// Cached arity of the Python `process()` function.
    /// 6 = with transport dict, 5 = with params, 4 = legacy.
    process_arity: usize,
    /// Cached PyList wrapping py_input_arrays (rebuilt on channel count change).
    py_input_list: Option<Py<PyAny>>,
    /// Cached PyList wrapping py_output_arrays (rebuilt on channel count change).
    py_output_list: Option<Py<PyAny>>,
    /// Cached PyDict for transport state (created once, values updated in-place).
    py_transport_dict: Option<Py<PyAny>>,
    /// Cached PyDict for params when using rich metadata (created once, values updated in-place).
    py_params_dict: Option<Py<PyAny>>,
}

impl PythonBackend {
    /// Load a Python script containing a `process()` function.
    /// `python_home` sets PYTHONHOME before interpreter init.
    pub fn load(python_home: &str, script_path: &str) -> Result<Self, String> {
        eprintln!(
            "ConjureDSP-Rust: PythonBackend::load called, python_home={}, script_path={}",
            python_home, script_path
        );

        // Set PYTHONHOME so the embedded interpreter finds its stdlib + numpy
        std::env::set_var("PYTHONHOME", python_home);

        // Prevent Python from writing .pyc bytecode cache files into the sealed
        // AU bundle's Resources/python-dist/, which corrupts the code signature.
        std::env::set_var("PYTHONDONTWRITEBYTECODE", "1");

        let result: Result<(Py<PyAny>, HashMap<u8, String>, Option<Vec<ParamMetadata>>, usize), PyErr> =
            Python::with_gil(|py| {
                let code = std::fs::read_to_string(script_path)
                    .map_err(|e| pyo3::exceptions::PyIOError::new_err(e.to_string()))?;

                let code_c = CString::new(code)
                    .map_err(|e| pyo3::exceptions::PyValueError::new_err(e.to_string()))?;
                let path_c = CString::new(script_path)
                    .map_err(|e| pyo3::exceptions::PyValueError::new_err(e.to_string()))?;
                let module_name = CString::new("dsp_script")
                    .map_err(|e| pyo3::exceptions::PyValueError::new_err(e.to_string()))?;

                // Remove any cached module so from_code creates a fresh one.
                // Without this, attributes from a previous script (like PARAM_NAMES or PARAMS)
                // persist in the module's __dict__ even if the new script doesn't define them.
                let sys_modules = py.import("sys")?.getattr("modules")?;
                let _ = sys_modules.call_method1("pop", ("dsp_script", py.None()));

                let module = PyModule::from_code(py, &code_c, &path_c, &module_name)?;
                let process_fn = module.getattr("process")?;

                // Detect process() arity via __code__.co_argcount for fast dispatch.
                // 6 = with transport, 5 = with params, 4 = legacy.
                let arity: usize = process_fn
                    .getattr("__code__")?
                    .getattr("co_argcount")?
                    .extract()?;

                // Try PARAMS dict first (rich metadata):
                //   PARAMS = {"threshold": {"min": -40, "max": -3, "unit": "dB", "default": -20}, ...}
                let (param_names, param_metadata) =
                    Self::extract_params(py, &module);

                Ok((process_fn.unbind(), param_names, param_metadata, arity))
            });

        match result {
            Ok((process_fn, param_names, param_metadata, arity)) => {
                eprintln!("ConjureDSP-Rust: Python script loaded successfully (arity={})", arity);
                Ok(Self {
                    py_process_fn: process_fn,
                    py_input_arrays: Vec::new(),
                    py_output_arrays: Vec::new(),
                    py_channel_count: 0,
                    last_error: None,
                    param_names,
                    param_metadata,
                    process_arity: arity,
                    py_input_list: None,
                    py_output_list: None,
                    py_transport_dict: None,
                    py_params_dict: None,
                })
            }
            Err(e) => {
                let err_msg = format!(
                    "python_home: {}\nscript_path: {}\nerror: {:?}",
                    python_home, script_path, e
                );
                Python::with_gil(|py| e.print(py));
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
            if self.process_arity >= 6 {
                let dict = PyDict::new(py);
                let _ = dict.set_item("tempo", 120.0f64);
                let _ = dict.set_item("beat", 0.0f64);
                let _ = dict.set_item("playing", false);
                let _ = dict.set_item("time_sig_num", 4.0f64);
                let _ = dict.set_item("time_sig_den", 4.0f64);
                let _ = dict.set_item("sample_position", 0.0f64);
                self.py_transport_dict = Some(dict.into_any().unbind());
            }

            // Cache params dict (keys are stable, values updated in-place each callback)
            if let Some(ref metadata) = self.param_metadata {
                let dict = PyDict::new(py);
                for meta in metadata.iter() {
                    let _ = dict.set_item(&meta.key, meta.default);
                }
                self.py_params_dict = Some(dict.into_any().unbind());
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
        let arity = self.process_arity;
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
            } else {
                PyList::new(py, params.iter())?.into_any()
            };

            // Dispatch by cached arity (detected at load time):
            // 6-arg: process(inputs, outputs, frame_count, sample_rate, params, transport)
            // 5-arg: process(inputs, outputs, frame_count, sample_rate, params)
            // 4-arg: process(inputs, outputs, frame_count, sample_rate)  [legacy]
            match arity {
                6.. => {
                    // Update cached transport dict values in-place
                    let transport_obj = if let Some(ref cached) = self.py_transport_dict {
                        let dict = cached.bind(py);
                        dict.set_item("tempo", transport.tempo)?;
                        dict.set_item("beat", transport.beat_position)?;
                        dict.set_item("playing", transport.is_playing)?;
                        dict.set_item("time_sig_num", transport.time_sig_numerator)?;
                        dict.set_item("time_sig_den", transport.time_sig_denominator)?;
                        dict.set_item("sample_position", transport.sample_position)?;
                        dict.clone()
                    } else {
                        let dict = PyDict::new(py);
                        dict.set_item("tempo", transport.tempo)?;
                        dict.set_item("beat", transport.beat_position)?;
                        dict.set_item("playing", transport.is_playing)?;
                        dict.set_item("time_sig_num", transport.time_sig_numerator)?;
                        dict.set_item("time_sig_den", transport.time_sig_denominator)?;
                        dict.set_item("sample_position", transport.sample_position)?;
                        dict.into_any()
                    };
                    self.py_process_fn.call1(
                        py,
                        (input_list, output_list, frame_count as u32, sample_rate, params_obj, transport_obj),
                    )?;
                }
                5 => {
                    self.py_process_fn.call1(
                        py,
                        (input_list, output_list, frame_count as u32, sample_rate, params_obj),
                    )?;
                }
                _ => {
                    self.py_process_fn.call1(
                        py,
                        (input_list, output_list, frame_count as u32, sample_rate),
                    )?;
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
                let err_msg = format!("Python process error: {}", e);
                self.last_error = Some(err_msg);
                Python::with_gil(|py| e.print(py));
                false
            }
        }
    }
}

impl Backend for PythonBackend {
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
}
