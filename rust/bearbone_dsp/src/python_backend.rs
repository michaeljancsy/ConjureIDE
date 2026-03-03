use crate::backend::Backend;
use numpy::{PyArray1, PyArrayMethods};
use pyo3::prelude::*;
use pyo3::types::PyList;
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

        let result: Result<Py<PyAny>, PyErr> = Python::with_gil(|py| {
            let code = std::fs::read_to_string(script_path)
                .map_err(|e| pyo3::exceptions::PyIOError::new_err(e.to_string()))?;

            let code_c = CString::new(code)
                .map_err(|e| pyo3::exceptions::PyValueError::new_err(e.to_string()))?;
            let path_c = CString::new(script_path)
                .map_err(|e| pyo3::exceptions::PyValueError::new_err(e.to_string()))?;
            let module_name = CString::new("dsp_script")
                .map_err(|e| pyo3::exceptions::PyValueError::new_err(e.to_string()))?;

            let module = PyModule::from_code(py, &code_c, &path_c, &module_name)?;
            let process_fn = module.getattr("process")?;
            Ok(process_fn.unbind())
        });

        match result {
            Ok(process_fn) => {
                eprintln!("BearBone-Rust: Python script loaded successfully");
                Ok(Self {
                    py_process_fn: process_fn,
                    py_input_arrays: Vec::new(),
                    py_output_arrays: Vec::new(),
                    py_channel_count: 0,
                    last_error: None,
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
        &self,
        inputs: &[*const f32],
        outputs: &[*mut f32],
        channel_count: usize,
        frame_count: usize,
        sample_rate: f64,
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

            // Call: process(inputs, outputs, frame_count, sample_rate)
            self.py_process_fn
                .call1(py, (input_list, output_list, frame_count as u32, sample_rate))?;

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
    ) -> bool {
        if self.py_input_arrays.is_empty() {
            return false;
        }
        self.process_with_python(inputs, outputs, channel_count, frame_count, sample_rate)
    }

    fn last_error(&self) -> Option<&str> {
        self.last_error.as_deref()
    }
}
