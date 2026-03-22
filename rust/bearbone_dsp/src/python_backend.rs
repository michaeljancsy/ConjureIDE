use crate::backend::Backend;
use crate::params::PARAM_COUNT;
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
}

impl PythonBackend {
    /// Load a Python script containing a `process()` function.
    /// `python_home` sets PYTHONHOME before interpreter init.
    pub fn load(python_home: &str, script_path: &str) -> Result<Self, String> {
        eprintln!(
            "BearBone-Rust: PythonBackend::load called, python_home={}, script_path={}",
            python_home, script_path
        );

        // Set PYTHONHOME so the embedded interpreter finds its stdlib + numpy
        std::env::set_var("PYTHONHOME", python_home);

        // Prevent Python from writing .pyc bytecode cache files into the sealed
        // AU bundle's Resources/python-dist/, which corrupts the code signature.
        std::env::set_var("PYTHONDONTWRITEBYTECODE", "1");

        let result: Result<(Py<PyAny>, HashMap<u8, String>), PyErr> = Python::with_gil(|py| {
            let code = std::fs::read_to_string(script_path)
                .map_err(|e| pyo3::exceptions::PyIOError::new_err(e.to_string()))?;

            let code_c = CString::new(code)
                .map_err(|e| pyo3::exceptions::PyValueError::new_err(e.to_string()))?;
            let path_c = CString::new(script_path)
                .map_err(|e| pyo3::exceptions::PyValueError::new_err(e.to_string()))?;
            let module_name = CString::new("dsp_script")
                .map_err(|e| pyo3::exceptions::PyValueError::new_err(e.to_string()))?;

            // Remove any cached module so from_code creates a fresh one.
            // Without this, attributes from a previous script (like PARAM_NAMES)
            // persist in the module's __dict__ even if the new script doesn't define them.
            let sys_modules = py.import("sys")?.getattr("modules")?;
            let _ = sys_modules.call_method1("pop", ("dsp_script", py.None()));

            let module = PyModule::from_code(py, &code_c, &path_c, &module_name)?;
            let process_fn = module.getattr("process")?;

            // Extract PARAM_NAMES dict if declared (e.g. {0: "Cutoff", 1: "Resonance"})
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

            Ok((process_fn.unbind(), param_names))
        });

        match result {
            Ok((process_fn, param_names)) => {
                eprintln!("BearBone-Rust: Python script loaded successfully");
                Ok(Self {
                    py_process_fn: process_fn,
                    py_input_arrays: Vec::new(),
                    py_output_arrays: Vec::new(),
                    py_channel_count: 0,
                    last_error: None,
                    param_names,
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

    /// Allocate numpy arrays for the given channel count, sized to max_frames.
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

            // Build Python lists referencing the pre-allocated arrays
            let input_list =
                PyList::new(py, self.py_input_arrays.iter().map(|a| a.bind(py)))?;
            let output_list =
                PyList::new(py, self.py_output_arrays.iter().map(|a| a.bind(py)))?;

            // Build params list (8 floats)
            let params_list = PyList::new(py, params.iter())?;

            // Try 5-arg call first: process(inputs, outputs, frame_count, sample_rate, params)
            // Fall back to 4-arg call for backward compatibility with old scripts.
            let call_result = self.py_process_fn
                .call1(py, (input_list.clone(), output_list.clone(), frame_count as u32, sample_rate, params_list));

            match call_result {
                Ok(_) => {}
                Err(e) => {
                    // Check if this is a TypeError from wrong arg count — fall back to 4-arg
                    if e.is_instance_of::<pyo3::exceptions::PyTypeError>(py) {
                        self.py_process_fn
                            .call1(py, (input_list, output_list, frame_count as u32, sample_rate))?;
                    } else {
                        return Err(e);
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
    ) -> bool {
        if self.py_input_arrays.is_empty() {
            self.last_error = Some("Python arrays not allocated — initialize() not called or failed".to_string());
            return false;
        }
        self.process_with_python(inputs, outputs, channel_count, frame_count, sample_rate, params)
    }

    fn last_error(&self) -> Option<&str> {
        self.last_error.as_deref()
    }

    fn param_names(&self) -> HashMap<u8, String> {
        self.param_names.clone()
    }
}
