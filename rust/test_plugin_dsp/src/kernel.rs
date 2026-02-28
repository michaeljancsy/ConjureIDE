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

    pub fn set_parameter(&mut self, _address: u64, _value: f32) {
        // No parameters currently defined
    }

    pub fn get_parameter(&self, _address: u64) -> f32 {
        0.0
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

    /// Benchmark the Python process function with a 440 Hz sine wave.
    /// Returns the max execution time in seconds over 5 runs (after 1 warm-up),
    /// or None if no script is loaded.
    pub fn benchmark_process(&mut self) -> Option<f64> {
        if self.py_process_fn.is_none() {
            return None;
        }

        let channel_count = if self.py_channel_count > 0 {
            self.py_channel_count
        } else {
            2
        };
        let frame_count = self.max_frames_to_render as usize;

        // Temporarily allocate numpy arrays if needed
        let needs_temp_arrays = self.py_input_arrays.is_empty();
        if needs_temp_arrays {
            self.allocate_py_arrays(channel_count);
        }

        // Generate 440 Hz sine wave input
        let sample_rate = if self.sample_rate > 0.0 {
            self.sample_rate
        } else {
            44100.0
        };
        let input_data: Vec<Vec<f32>> = (0..channel_count)
            .map(|_| {
                (0..frame_count)
                    .map(|i| (2.0 * std::f32::consts::PI * 440.0 * i as f32 / sample_rate as f32).sin())
                    .collect()
            })
            .collect();
        let mut output_data: Vec<Vec<f32>> =
            (0..channel_count).map(|_| vec![0.0f32; frame_count]).collect();

        let input_ptrs: Vec<*const f32> = input_data.iter().map(|v| v.as_ptr()).collect();
        let output_ptrs: Vec<*mut f32> = output_data.iter_mut().map(|v| v.as_mut_ptr()).collect();

        // Warm-up
        unsafe {
            self.process(
                input_ptrs.as_ptr(),
                output_ptrs.as_ptr(),
                channel_count as u32,
                self.max_frames_to_render,
            );
        }

        // Timed runs
        let n = 5;
        let mut max_time = 0.0f64;
        for _ in 0..n {
            let start = std::time::Instant::now();
            unsafe {
                self.process(
                    input_ptrs.as_ptr(),
                    output_ptrs.as_ptr(),
                    channel_count as u32,
                    self.max_frames_to_render,
                );
            }
            let elapsed = start.elapsed().as_secs_f64();
            if elapsed > max_time {
                max_time = elapsed;
            }
        }

        // Clean up temp arrays
        if needs_temp_arrays {
            Python::with_gil(|_py| {
                self.py_input_arrays.clear();
                self.py_output_arrays.clear();
            });
        }

        Some(max_time)
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

        // Fallback: passthrough (copy input to output unchanged)
        for ch in 0..channel_count {
            let src = std::slice::from_raw_parts(inputs[ch], frame_count);
            let dst = std::slice::from_raw_parts_mut(outputs[ch], frame_count);
            dst.copy_from_slice(src);
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

    // --- Helper ---

    /// Returns (python_home, script_path) for integration tests.
    /// Returns None if the bundled Python runtime hasn't been set up.
    fn test_python_paths() -> Option<(String, String)> {
        let manifest_dir = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        let python_home = manifest_dir.join("../python-dist");
        let script_path = manifest_dir.join("../../TestPluginExtension/Resources/process.py");
        if python_home.exists() && script_path.exists() {
            Some((
                python_home.to_string_lossy().into_owned(),
                script_path.to_string_lossy().into_owned(),
            ))
        } else {
            None
        }
    }

    // --- Group A: No Python required ---

    #[test]
    fn test_bypass_passes_through() {
        let mut kernel = DSPKernel::new();
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

    #[test]
    fn test_new_kernel_defaults() {
        let kernel = DSPKernel::new();
        assert_eq!(kernel.sample_rate, 44100.0);
        assert!(!kernel.is_bypassed());
        assert_eq!(kernel.maximum_frames_to_render(), 1024);
        assert!(kernel.last_error().is_none());
    }

    #[test]
    fn test_bypass_toggle() {
        let mut kernel = DSPKernel::new();
        assert!(!kernel.is_bypassed());
        kernel.set_bypassed(true);
        assert!(kernel.is_bypassed());
        kernel.set_bypassed(false);
        assert!(!kernel.is_bypassed());
    }

    #[test]
    fn test_set_max_frames() {
        let mut kernel = DSPKernel::new();
        assert_eq!(kernel.maximum_frames_to_render(), 1024);
        kernel.set_maximum_frames_to_render(512);
        assert_eq!(kernel.maximum_frames_to_render(), 512);
        kernel.set_maximum_frames_to_render(4096);
        assert_eq!(kernel.maximum_frames_to_render(), 4096);
    }

    #[test]
    fn test_passthrough_when_no_script() {
        let kernel = DSPKernel::new(); // not bypassed, no script loaded

        let input: [f32; 4] = [0.1, 0.2, 0.3, 0.4];
        let mut output: [f32; 4] = [0.0; 4];

        let input_ptr: *const f32 = input.as_ptr();
        let output_ptr: *mut f32 = output.as_mut_ptr();

        unsafe {
            kernel.process(&input_ptr, &output_ptr, 1, 4);
        }

        assert_eq!(output, [0.1, 0.2, 0.3, 0.4]);
    }

    #[test]
    fn test_passthrough_stereo() {
        let kernel = DSPKernel::new();

        let input_l: [f32; 4] = [1.0, 0.5, -1.0, 0.0];
        let input_r: [f32; 4] = [0.0, -0.5, 1.0, 0.25];
        let mut output_l: [f32; 4] = [0.0; 4];
        let mut output_r: [f32; 4] = [0.0; 4];

        let input_ptrs: [*const f32; 2] = [input_l.as_ptr(), input_r.as_ptr()];
        let output_ptrs: [*mut f32; 2] = [output_l.as_mut_ptr(), output_r.as_mut_ptr()];

        unsafe {
            kernel.process(input_ptrs.as_ptr(), output_ptrs.as_ptr(), 2, 4);
        }

        assert_eq!(output_l, [1.0, 0.5, -1.0, 0.0]);
        assert_eq!(output_r, [0.0, -0.5, 1.0, 0.25]);
    }

    #[test]
    fn test_bypass_stereo() {
        let mut kernel = DSPKernel::new();
        kernel.set_bypassed(true);

        let input_l: [f32; 4] = [1.0, 0.5, -1.0, 0.0];
        let input_r: [f32; 4] = [0.0, -0.5, 1.0, 0.25];
        let mut output_l: [f32; 4] = [0.0; 4];
        let mut output_r: [f32; 4] = [0.0; 4];

        let input_ptrs: [*const f32; 2] = [input_l.as_ptr(), input_r.as_ptr()];
        let output_ptrs: [*mut f32; 2] = [output_l.as_mut_ptr(), output_r.as_mut_ptr()];

        unsafe {
            kernel.process(input_ptrs.as_ptr(), output_ptrs.as_ptr(), 2, 4);
        }

        assert_eq!(output_l, [1.0, 0.5, -1.0, 0.0]);
        assert_eq!(output_r, [0.0, -0.5, 1.0, 0.25]);
    }

    #[test]
    fn test_initialize_sets_sample_rate() {
        let mut kernel = DSPKernel::new();
        assert_eq!(kernel.sample_rate, 44100.0);
        kernel.initialize(2, 2, 48000.0);
        assert_eq!(kernel.sample_rate, 48000.0);
    }

    #[test]
    fn test_last_error_initially_none() {
        let kernel = DSPKernel::new();
        assert!(kernel.last_error().is_none());
    }

    // --- Group A2: Edge cases (no Python) ---

    #[test]
    fn test_initialize_deinitialize_cycle() {
        let mut kernel = DSPKernel::new();
        for _ in 0..3 {
            kernel.initialize(2, 2, 48000.0);
            let input: [f32; 4] = [1.0; 4];
            let mut output: [f32; 4] = [0.0; 4];
            let ip: *const f32 = input.as_ptr();
            let op: *mut f32 = output.as_mut_ptr();
            unsafe { kernel.process(&ip, &op, 1, 4); }
            assert_eq!(output, [1.0; 4]);
            kernel.deinitialize();
        }
    }

    #[test]
    fn test_deinitialize_without_initialize() {
        let mut kernel = DSPKernel::new();
        kernel.deinitialize(); // should not panic
    }

    #[test]
    fn test_process_single_frame() {
        let kernel = DSPKernel::new();
        let input: [f32; 1] = [0.75];
        let mut output: [f32; 1] = [0.0];
        let ip: *const f32 = input.as_ptr();
        let op: *mut f32 = output.as_mut_ptr();
        unsafe { kernel.process(&ip, &op, 1, 1); }
        assert_eq!(output, [0.75]);
    }

    #[test]
    fn test_process_large_buffer() {
        let mut kernel = DSPKernel::new();
        kernel.set_maximum_frames_to_render(4096);
        let input = vec![0.5f32; 4096];
        let mut output = vec![0.0f32; 4096];
        let ip: *const f32 = input.as_ptr();
        let op: *mut f32 = output.as_mut_ptr();
        unsafe { kernel.process(&ip, &op, 1, 4096); }
        assert!(output.iter().all(|&s| s == 0.5));
    }

    #[test]
    fn test_initialize_changes_channel_count() {
        let mut kernel = DSPKernel::new();
        kernel.initialize(1, 1, 44100.0);
        assert_eq!(kernel.py_channel_count, 1);
        kernel.deinitialize();
        kernel.initialize(2, 2, 48000.0);
        assert_eq!(kernel.py_channel_count, 2);
    }

    #[test]
    fn test_bypass_toggle_mid_stream() {
        let mut kernel = DSPKernel::new();
        let input: [f32; 4] = [1.0, 0.5, -1.0, 0.0];
        let mut output: [f32; 4] = [0.0; 4];
        let ip: *const f32 = input.as_ptr();
        let op: *mut f32 = output.as_mut_ptr();

        // Process with bypass on
        kernel.set_bypassed(true);
        unsafe { kernel.process(&ip, &op, 1, 4); }
        assert_eq!(output, [1.0, 0.5, -1.0, 0.0]);

        // Process with bypass off (still passthrough, no script)
        kernel.set_bypassed(false);
        output = [0.0; 4];
        unsafe { kernel.process(&ip, &op, 1, 4); }
        assert_eq!(output, [1.0, 0.5, -1.0, 0.0]);
    }

    // --- Group B: Requires bundled Python runtime ---

    /// Write a Python script to a temp file and return the path.
    fn write_temp_script(source: &str) -> std::path::PathBuf {
        use std::sync::atomic::{AtomicU64, Ordering};
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let id = COUNTER.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!("test_dsp_{}_{}.py", std::process::id(), id));
        std::fs::write(&path, source).expect("failed to write temp script");
        path
    }

    #[test]
    fn test_load_script_success() {
        let (python_home, script_path) = match test_python_paths() {
            Some(paths) => paths,
            None => {
                eprintln!("Skipping: bundled Python runtime not found");
                return;
            }
        };

        let mut kernel = DSPKernel::new();
        let result = kernel.load_script(&python_home, &script_path);
        assert!(result, "load_script should succeed with valid paths");
        assert!(kernel.last_error().is_none());
    }

    #[test]
    fn test_load_script_bad_path() {
        let (python_home, _) = match test_python_paths() {
            Some(paths) => paths,
            None => {
                eprintln!("Skipping: bundled Python runtime not found");
                return;
            }
        };

        let mut kernel = DSPKernel::new();
        let result = kernel.load_script(&python_home, "/nonexistent/script.py");
        assert!(!result, "load_script should fail with bad path");
        assert!(kernel.last_error().is_some());
    }

    #[test]
    fn test_process_with_python_applies_gain() {
        let (python_home, script_path) = match test_python_paths() {
            Some(paths) => paths,
            None => {
                eprintln!("Skipping: bundled Python runtime not found");
                return;
            }
        };

        let mut kernel = DSPKernel::new();
        assert!(kernel.load_script(&python_home, &script_path));
        kernel.initialize(1, 1, 44100.0);

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
    fn test_process_with_python_stereo() {
        let (python_home, script_path) = match test_python_paths() {
            Some(paths) => paths,
            None => {
                eprintln!("Skipping: bundled Python runtime not found");
                return;
            }
        };

        let mut kernel = DSPKernel::new();
        assert!(kernel.load_script(&python_home, &script_path));
        kernel.initialize(2, 2, 44100.0);

        let input_l: [f32; 4] = [1.0, 0.5, -1.0, 0.0];
        let input_r: [f32; 4] = [0.2, 0.4, 0.6, 0.8];
        let mut output_l: [f32; 4] = [0.0; 4];
        let mut output_r: [f32; 4] = [0.0; 4];

        let input_ptrs: [*const f32; 2] = [input_l.as_ptr(), input_r.as_ptr()];
        let output_ptrs: [*mut f32; 2] = [output_l.as_mut_ptr(), output_r.as_mut_ptr()];

        unsafe {
            kernel.process(input_ptrs.as_ptr(), output_ptrs.as_ptr(), 2, 4);
        }

        assert_eq!(output_l, [0.5, 0.25, -0.5, 0.0]);
        assert_eq!(output_r, [0.1, 0.2, 0.3, 0.4]);
    }

    #[test]
    fn test_bypass_overrides_python() {
        let (python_home, script_path) = match test_python_paths() {
            Some(paths) => paths,
            None => {
                eprintln!("Skipping: bundled Python runtime not found");
                return;
            }
        };

        let mut kernel = DSPKernel::new();
        assert!(kernel.load_script(&python_home, &script_path));
        kernel.initialize(1, 1, 44100.0);
        kernel.set_bypassed(true);

        let input: [f32; 4] = [1.0, 0.5, -1.0, 0.0];
        let mut output: [f32; 4] = [0.0; 4];

        let input_ptr: *const f32 = input.as_ptr();
        let output_ptr: *mut f32 = output.as_mut_ptr();

        unsafe {
            kernel.process(&input_ptr, &output_ptr, 1, 4);
        }

        // Bypass should copy input unchanged, not apply 0.5x gain
        assert_eq!(output, [1.0, 0.5, -1.0, 0.0]);
    }

    // --- Group B2: Python error handling & hot-reload ---

    #[test]
    fn test_python_error_recovery_falls_back_to_passthrough() {
        let (python_home, _) = match test_python_paths() {
            Some(paths) => paths,
            None => { eprintln!("Skipping: bundled Python runtime not found"); return; }
        };
        let script = write_temp_script(
            "import numpy as np\ndef process(inputs, outputs, frame_count, sample_rate):\n    raise RuntimeError('intentional error')\n"
        );
        let mut kernel = DSPKernel::new();
        assert!(kernel.load_script(&python_home, script.to_str().unwrap()));
        kernel.initialize(1, 1, 44100.0);

        let input: [f32; 4] = [1.0, 0.5, -1.0, 0.0];
        let mut output: [f32; 4] = [0.0; 4];
        let ip: *const f32 = input.as_ptr();
        let op: *mut f32 = output.as_mut_ptr();
        unsafe { kernel.process(&ip, &op, 1, 4); }
        assert_eq!(output, [1.0, 0.5, -1.0, 0.0]);
        std::fs::remove_file(script).ok();
    }

    #[test]
    fn test_process_after_python_error_continues_working() {
        let (python_home, _) = match test_python_paths() {
            Some(paths) => paths,
            None => { eprintln!("Skipping: bundled Python runtime not found"); return; }
        };
        let script = write_temp_script(
            "import numpy as np\ndef process(inputs, outputs, frame_count, sr):\n    raise ValueError('boom')\n"
        );
        let mut kernel = DSPKernel::new();
        assert!(kernel.load_script(&python_home, script.to_str().unwrap()));
        kernel.initialize(1, 1, 44100.0);

        let input: [f32; 4] = [0.7, 0.7, 0.7, 0.7];
        let mut output: [f32; 4] = [0.0; 4];
        let ip: *const f32 = input.as_ptr();
        let op: *mut f32 = output.as_mut_ptr();

        for _ in 0..5 {
            output = [0.0; 4];
            unsafe { kernel.process(&ip, &op, 1, 4); }
            assert_eq!(output, [0.7, 0.7, 0.7, 0.7]);
        }
        std::fs::remove_file(script).ok();
    }

    #[test]
    fn test_script_hot_reload() {
        let (python_home, _) = match test_python_paths() {
            Some(paths) => paths,
            None => { eprintln!("Skipping: bundled Python runtime not found"); return; }
        };
        let script_half = write_temp_script(
            "import numpy as np\ndef process(inputs, outputs, frame_count, sr):\n    for ch in range(len(inputs)):\n        outputs[ch][:frame_count] = inputs[ch][:frame_count] * 0.5\n"
        );
        let mut kernel = DSPKernel::new();
        assert!(kernel.load_script(&python_home, script_half.to_str().unwrap()));
        kernel.initialize(1, 1, 44100.0);

        let input: [f32; 4] = [1.0, 1.0, 1.0, 1.0];
        let mut output: [f32; 4] = [0.0; 4];
        let ip: *const f32 = input.as_ptr();
        let op: *mut f32 = output.as_mut_ptr();
        unsafe { kernel.process(&ip, &op, 1, 4); }
        assert_eq!(output, [0.5, 0.5, 0.5, 0.5]);

        // Hot-reload with a different gain
        let script_quarter = write_temp_script(
            "import numpy as np\ndef process(inputs, outputs, frame_count, sr):\n    for ch in range(len(inputs)):\n        outputs[ch][:frame_count] = inputs[ch][:frame_count] * 0.25\n"
        );
        assert!(kernel.load_script(&python_home, script_quarter.to_str().unwrap()));
        kernel.initialize(1, 1, 44100.0);

        output = [0.0; 4];
        unsafe { kernel.process(&ip, &op, 1, 4); }
        assert_eq!(output, [0.25, 0.25, 0.25, 0.25]);

        std::fs::remove_file(script_half).ok();
        std::fs::remove_file(script_quarter).ok();
    }

    #[test]
    fn test_load_script_missing_process_function() {
        let (python_home, _) = match test_python_paths() {
            Some(paths) => paths,
            None => { eprintln!("Skipping: bundled Python runtime not found"); return; }
        };
        let script = write_temp_script("import numpy as np\ndef not_process(): pass\n");
        let mut kernel = DSPKernel::new();
        let result = kernel.load_script(&python_home, script.to_str().unwrap());
        assert!(!result, "Should fail when process() function is missing");
        assert!(kernel.last_error().is_some());
        std::fs::remove_file(script).ok();
    }

    #[test]
    fn test_load_script_syntax_error() {
        let (python_home, _) = match test_python_paths() {
            Some(paths) => paths,
            None => { eprintln!("Skipping: bundled Python runtime not found"); return; }
        };
        let script = write_temp_script("def process(\n");
        let mut kernel = DSPKernel::new();
        let result = kernel.load_script(&python_home, script.to_str().unwrap());
        assert!(!result);
        assert!(kernel.last_error().is_some());
        std::fs::remove_file(script).ok();
    }

    #[test]
    fn test_load_script_import_error() {
        let (python_home, _) = match test_python_paths() {
            Some(paths) => paths,
            None => { eprintln!("Skipping: bundled Python runtime not found"); return; }
        };
        let script = write_temp_script("import nonexistent_module_xyz\ndef process(i,o,f,s): pass\n");
        let mut kernel = DSPKernel::new();
        let result = kernel.load_script(&python_home, script.to_str().unwrap());
        assert!(!result);
        assert!(kernel.last_error().is_some());
        std::fs::remove_file(script).ok();
    }

    // --- Group B3: Benchmarking ---

    #[test]
    fn test_benchmark_no_script() {
        let mut kernel = DSPKernel::new();
        assert!(kernel.benchmark_process().is_none());
    }

    #[test]
    fn test_benchmark_with_script() {
        let (python_home, script_path) = match test_python_paths() {
            Some(paths) => paths,
            None => { eprintln!("Skipping: bundled Python runtime not found"); return; }
        };
        let mut kernel = DSPKernel::new();
        assert!(kernel.load_script(&python_home, &script_path));
        kernel.initialize(2, 2, 44100.0);

        let result = kernel.benchmark_process();
        assert!(result.is_some());
        let time = result.unwrap();
        assert!(time > 0.0, "Benchmark time should be positive, got {}", time);
    }
}
