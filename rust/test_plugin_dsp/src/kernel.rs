use crate::params::PARAM_GAIN;
use numpy::{PyArray1, PyArrayMethods};
use pyo3::prelude::*;
use pyo3::types::PyList;
use std::ffi::CString;

/// Real-time audio DSP kernel with optional Python processing.
///
/// When a Python script is loaded, `process()` delegates to the script's
/// `process(inputs, outputs, frame_count, sample_rate)` function with
/// pre-allocated numpy arrays. When no script is loaded, the original
/// Rust gain processing is used as fallback.
pub struct DSPKernel {
    sample_rate: f64,
    gain: f64,
    bypassed: bool,
    max_frames_to_render: u32,

    // Python state
    py_process_fn: Option<Py<PyAny>>,
    py_input_arrays: Vec<Py<PyAny>>,
    py_output_arrays: Vec<Py<PyAny>>,
    py_channel_count: usize,

    // Last error message for diagnostics
    last_error: Option<String>,
}

impl DSPKernel {
    pub fn new() -> Self {
        Self {
            sample_rate: 44100.0,
            gain: 1.0,
            bypassed: false,
            max_frames_to_render: 1024,
            py_process_fn: None,
            py_input_arrays: Vec::new(),
            py_output_arrays: Vec::new(),
            py_channel_count: 0,
            last_error: None,
        }
    }

    pub fn initialize(&mut self, input_channels: i32, _output_channels: i32, sample_rate: f64) {
        self.sample_rate = sample_rate;
        let channel_count = input_channels as usize;
        self.py_channel_count = channel_count;

        // Pre-allocate numpy arrays if Python is loaded
        if self.py_process_fn.is_some() {
            self.allocate_py_arrays(channel_count);
        }
    }

    /// Allocate numpy arrays for the given channel count, sized to max_frames_to_render.
    fn allocate_py_arrays(&mut self, channel_count: usize) {
        let max_frames = self.max_frames_to_render as usize;

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
    }

    pub fn deinitialize(&mut self) {
        // Drop pre-allocated arrays (GIL needed to decref)
        if !self.py_input_arrays.is_empty() {
            Python::with_gil(|_py| {
                self.py_input_arrays.clear();
                self.py_output_arrays.clear();
            });
        }
    }

    /// Load a Python script containing a `process()` function.
    /// `python_home` sets PYTHONHOME before interpreter init.
    /// Returns true on success.
    pub fn load_script(&mut self, python_home: &str, script_path: &str) -> bool {
        // Log paths for debugging
        eprintln!("TestPlugin-Rust: load_script called, python_home={}, script_path={}", python_home, script_path);

        // Set PYTHONHOME so the embedded interpreter finds its stdlib + numpy
        std::env::set_var("PYTHONHOME", python_home);

        let result: Result<(), PyErr> = Python::with_gil(|py| {
            // Read the script source
            let code = std::fs::read_to_string(script_path)
                .map_err(|e| pyo3::exceptions::PyIOError::new_err(e.to_string()))?;

            // Convert to CString for pyo3 API
            let code_c = CString::new(code)
                .map_err(|e| pyo3::exceptions::PyValueError::new_err(e.to_string()))?;
            let path_c = CString::new(script_path)
                .map_err(|e| pyo3::exceptions::PyValueError::new_err(e.to_string()))?;
            let module_name = CString::new("dsp_script")
                .map_err(|e| pyo3::exceptions::PyValueError::new_err(e.to_string()))?;

            let module = PyModule::from_code(py, &code_c, &path_c, &module_name)?;
            let process_fn = module.getattr("process")?;
            self.py_process_fn = Some(process_fn.unbind());

            Ok(())
        });

        match result {
            Ok(()) => {
                // If already initialized with channels, allocate arrays now
                if self.py_channel_count > 0 {
                    self.allocate_py_arrays(self.py_channel_count);
                }
                eprintln!("TestPlugin-Rust: Python script loaded successfully");
                true
            }
            Err(e) => {
                let err_msg = format!("python_home: {}\nscript_path: {}\nerror: {:?}", python_home, script_path, e);
                self.last_error = Some(err_msg);
                Python::with_gil(|py| e.print(py));
                false
            }
        }
    }

    pub fn set_bypassed(&mut self, bypass: bool) {
        self.bypassed = bypass;
    }

    pub fn is_bypassed(&self) -> bool {
        self.bypassed
    }

    pub fn set_parameter(&mut self, address: u64, value: f32) {
        match address {
            PARAM_GAIN => self.gain = value as f64,
            _ => {}
        }
    }

    pub fn get_parameter(&self, address: u64) -> f32 {
        match address {
            PARAM_GAIN => self.gain as f32,
            _ => 0.0,
        }
    }

    pub fn maximum_frames_to_render(&self) -> u32 {
        self.max_frames_to_render
    }

    pub fn set_maximum_frames_to_render(&mut self, max_frames: u32) {
        self.max_frames_to_render = max_frames;
    }

    /// Returns the last error message, if any.
    pub fn last_error(&self) -> Option<&str> {
        self.last_error.as_deref()
    }

    /// Process audio buffers. Called from the real-time audio thread.
    ///
    /// If a Python script is loaded, delegates to Python with pre-allocated
    /// numpy arrays. Otherwise falls back to Rust gain processing.
    ///
    /// # Safety
    /// - `input_buffers` must point to `channel_count` valid `*const f32` pointers.
    /// - `output_buffers` must point to `channel_count` valid `*mut f32` pointers.
    /// - Each channel buffer must contain at least `frame_count` samples.
    pub unsafe fn process(
        &self,
        input_buffers: *const *const f32,
        output_buffers: *const *mut f32,
        channel_count: u32,
        frame_count: u32,
    ) {
        let channel_count = channel_count as usize;
        let frame_count = frame_count as usize;
        let inputs = std::slice::from_raw_parts(input_buffers, channel_count);
        let outputs = std::slice::from_raw_parts(output_buffers, channel_count);

        if self.bypassed {
            for ch in 0..channel_count {
                let src = std::slice::from_raw_parts(inputs[ch], frame_count);
                let dst = std::slice::from_raw_parts_mut(outputs[ch], frame_count);
                dst.copy_from_slice(src);
            }
            return;
        }

        // Try Python processing
        if self.py_process_fn.is_some() && !self.py_input_arrays.is_empty() {
            if self.process_with_python(inputs, outputs, channel_count, frame_count) {
                return;
            }
            // Python failed — fall through to Rust
        }

        // Fallback: Rust gain processing
        let gain = self.gain as f32;
        for ch in 0..channel_count {
            let src = std::slice::from_raw_parts(inputs[ch], frame_count);
            let dst = std::slice::from_raw_parts_mut(outputs[ch], frame_count);
            for i in 0..frame_count {
                dst[i] = src[i] * gain;
            }
        }
    }

    /// Delegate audio processing to the loaded Python script.
    /// Returns true on success.
    unsafe fn process_with_python(
        &self,
        inputs: &[*const f32],
        outputs: &[*mut f32],
        channel_count: usize,
        frame_count: usize,
    ) -> bool {
        let process_fn = match &self.py_process_fn {
            Some(f) => f,
            None => return false,
        };

        let result: Result<(), PyErr> = Python::with_gil(|py| {
            // Copy input audio data into pre-allocated numpy arrays
            for ch in 0..channel_count {
                let src = std::slice::from_raw_parts(inputs[ch], frame_count);
                let py_arr: &Bound<'_, PyArray1<f32>> = self.py_input_arrays[ch].bind(py).downcast()?;
                let py_slice = py_arr.as_slice_mut()?;
                py_slice[..frame_count].copy_from_slice(src);
            }

            // Build Python lists referencing the pre-allocated arrays
            let input_list = PyList::new(
                py,
                self.py_input_arrays.iter().map(|a| a.bind(py)),
            )?;
            let output_list = PyList::new(
                py,
                self.py_output_arrays.iter().map(|a| a.bind(py)),
            )?;

            // Call: process(inputs, outputs, frame_count, sample_rate)
            process_fn.call1(
                py,
                (input_list, output_list, frame_count as u32, self.sample_rate),
            )?;

            // Copy output from pre-allocated numpy arrays back to audio buffers
            for ch in 0..channel_count {
                let dst = std::slice::from_raw_parts_mut(outputs[ch], frame_count);
                let py_arr: &Bound<'_, PyArray1<f32>> = self.py_output_arrays[ch].bind(py).downcast()?;
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_gain() {
        let kernel = DSPKernel::new();
        assert_eq!(kernel.get_parameter(PARAM_GAIN), 1.0);
    }

    #[test]
    fn test_set_get_parameter() {
        let mut kernel = DSPKernel::new();
        kernel.set_parameter(PARAM_GAIN, 0.5);
        assert!((kernel.get_parameter(PARAM_GAIN) - 0.5).abs() < f32::EPSILON);
    }

    #[test]
    fn test_process_applies_gain() {
        let mut kernel = DSPKernel::new();
        kernel.set_parameter(PARAM_GAIN, 0.5);

        let input: [f32; 4] = [1.0, 0.5, -1.0, 0.0];
        let mut output: [f32; 4] = [0.0; 4];

        let input_ptr: *const f32 = input.as_ptr();
        let output_ptr: *mut f32 = output.as_mut_ptr();

        unsafe {
            kernel.process(&input_ptr, &output_ptr, 1, 4);
        }

        assert_eq!(output, [0.5, 0.25, -0.5, 0.0]);
    }

    #[test]
    fn test_bypass_passes_through() {
        let mut kernel = DSPKernel::new();
        kernel.set_parameter(PARAM_GAIN, 0.5);
        kernel.set_bypassed(true);

        let input: [f32; 4] = [1.0, 0.5, -1.0, 0.0];
        let mut output: [f32; 4] = [0.0; 4];

        let input_ptr: *const f32 = input.as_ptr();
        let output_ptr: *mut f32 = output.as_mut_ptr();

        unsafe {
            kernel.process(&input_ptr, &output_ptr, 1, 4);
        }

        assert_eq!(output, [1.0, 0.5, -1.0, 0.0]);
    }

    #[test]
    fn test_unknown_parameter_returns_zero() {
        let kernel = DSPKernel::new();
        assert_eq!(kernel.get_parameter(999), 0.0);
    }
}
