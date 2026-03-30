//! Standalone tests verifying that multiple pyo3-based DSP backends can coexist
//! safely in a single process, reproducing the exact loading pattern used by
//! ConjureDSP's PythonBackend.
//!
//! Run with:
//!   cd rust/multi_instance_test
//!   DYLD_LIBRARY_PATH="$(cd ../python-dist/lib && pwd)" \
//!     PYO3_PYTHON="$(cd ../python-dist/bin && pwd)/python3" \
//!     cargo test -- --test-threads=1
//!
//! --test-threads=1 is required because all tests share a single Python interpreter.

#![allow(deprecated)] // pyo3 0.27: with_gil → attach, downcast → cast

use numpy::{PyArray1, PyArrayMethods};
use pyo3::prelude::*;
use pyo3::types::PyList;
use std::ffi::CString;
use std::path::PathBuf;

// ---------------------------------------------------------------------------
// Minimal reproduction of PythonBackend's load + process pattern
// ---------------------------------------------------------------------------

/// A minimal reproduction of ConjureDSP's PythonBackend, keeping only what's
/// needed to test multi-instance isolation.
struct MiniBackend {
    /// Reference to the script's process() function (prevent GC).
    process_fn: Py<PyAny>,
    /// Pre-allocated numpy input arrays, one per channel.
    input_arrays: Vec<Py<PyAny>>,
    /// Pre-allocated numpy output arrays, one per channel.
    output_arrays: Vec<Py<PyAny>>,
}

impl MiniBackend {
    /// Load a Python script using the SAME pattern as PythonBackend::load().
    /// `module_name` controls the key in sys.modules — this is what we're testing.
    fn load(script_source: &str, module_name: &str) -> Self {
        Python::with_gil(|py| {
            let code = CString::new(script_source).unwrap();
            let path = CString::new("<test>").unwrap();
            let mod_name = CString::new(module_name).unwrap();

            // Pop any cached module (same as python_backend.rs:84-89)
            let sys = py.import("sys").unwrap();
            let sys_modules = sys.getattr("modules").unwrap();
            let _ = sys_modules.call_method1("pop", (module_name, py.None()));

            let module = PyModule::from_code(py, &code, &path, &mod_name).unwrap();
            let process_fn = module.getattr("process").unwrap().unbind();

            MiniBackend {
                process_fn,
                input_arrays: Vec::new(),
                output_arrays: Vec::new(),
            }
        })
    }

    /// Allocate numpy arrays for the given channel count and frame size.
    fn initialize(&mut self, channels: usize, max_frames: usize) {
        Python::with_gil(|py| {
            self.input_arrays.clear();
            self.output_arrays.clear();
            for _ in 0..channels {
                let inp = PyArray1::<f32>::zeros(py, max_frames, false);
                let out = PyArray1::<f32>::zeros(py, max_frames, false);
                self.input_arrays.push(inp.into_any().unbind());
                self.output_arrays.push(out.into_any().unbind());
            }
        });
    }

    /// Process audio: copy input → numpy, call process(), copy numpy → output.
    fn process(&self, inputs: &[&[f32]], outputs: &mut [Vec<f32>], frame_count: usize) {
        Python::with_gil(|py| {
            let channels = inputs.len();

            // Copy input data into numpy arrays
            for ch in 0..channels {
                let arr = self.input_arrays[ch]
                    .bind(py)
                    .downcast::<PyArray1<f32>>()
                    .unwrap();
                unsafe {
                    let slice = arr.as_slice_mut().unwrap();
                    slice[..frame_count].copy_from_slice(&inputs[ch][..frame_count]);
                }
            }

            // Zero output arrays
            for ch in 0..channels {
                let arr = self.output_arrays[ch]
                    .bind(py)
                    .downcast::<PyArray1<f32>>()
                    .unwrap();
                unsafe {
                    let slice = arr.as_slice_mut().unwrap();
                    slice[..frame_count].fill(0.0);
                }
            }

            // Build input/output lists
            let input_list =
                PyList::new(py, self.input_arrays.iter().map(|a| a.bind(py))).unwrap();
            let output_list =
                PyList::new(py, self.output_arrays.iter().map(|a| a.bind(py))).unwrap();

            // Call process(inputs, outputs, frame_count, sample_rate)
            self.process_fn
                .call1(py, (input_list, output_list, frame_count, 48000.0f64))
                .unwrap();

            // Copy output back
            for ch in 0..channels {
                let arr = self.output_arrays[ch]
                    .bind(py)
                    .downcast::<PyArray1<f32>>()
                    .unwrap();
                unsafe {
                    let slice = arr.as_slice().unwrap();
                    outputs[ch][..frame_count].copy_from_slice(&slice[..frame_count]);
                }
            }
        });
    }
}

// ---------------------------------------------------------------------------
// Helper
// ---------------------------------------------------------------------------

fn setup_python() {
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let home = manifest.join("../python-dist");
    if !home.exists() {
        panic!(
            "Bundled Python not found at {:?}. Run rust/setup-python.sh first.",
            home
        );
    }
    std::env::set_var("PYTHONHOME", home.to_str().unwrap());
    std::env::set_var("PYTHONDONTWRITEBYTECODE", "1");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    // -----------------------------------------------------------------------
    // Test 1: Two instances with different scripts produce correct output
    // -----------------------------------------------------------------------
    #[test]
    fn test_two_instances_different_scripts_sequential() {
        setup_python();

        let script_half = r#"
import numpy as np
def process(inputs, outputs, frame_count, sample_rate):
    for ch in range(len(inputs)):
        outputs[ch][:frame_count] = inputs[ch][:frame_count] * 0.5
"#;

        let script_double = r#"
import numpy as np
def process(inputs, outputs, frame_count, sample_rate):
    for ch in range(len(inputs)):
        outputs[ch][:frame_count] = inputs[ch][:frame_count] * 2.0
"#;

        // Use unique module names (the proposed fix)
        let mut backend_a = MiniBackend::load(script_half, "dsp_instance_0");
        let mut backend_b = MiniBackend::load(script_double, "dsp_instance_1");

        backend_a.initialize(1, 4);
        backend_b.initialize(1, 4);

        let input = vec![1.0f32, 0.5, -1.0, 0.0];
        let mut out_a = vec![vec![0.0f32; 4]];
        let mut out_b = vec![vec![0.0f32; 4]];

        backend_a.process(&[&input], &mut out_a, 4);
        backend_b.process(&[&input], &mut out_b, 4);

        assert_eq!(out_a[0], vec![0.5, 0.25, -0.5, 0.0], "backend A (half)");
        assert_eq!(out_b[0], vec![2.0, 1.0, -2.0, 0.0], "backend B (double)");
    }

    // -----------------------------------------------------------------------
    // Test 2: Module-level mutable state is isolated between instances
    // -----------------------------------------------------------------------
    #[test]
    fn test_module_level_state_isolation() {
        setup_python();

        let script_with_counter = |id: &str| {
            format!(
                r#"
import numpy as np
call_count = 0
instance_id = "{id}"

def process(inputs, outputs, frame_count, sample_rate):
    global call_count
    call_count += 1
    outputs[0][0] = float(call_count)
    for ch in range(len(inputs)):
        outputs[ch][1:frame_count] = inputs[ch][1:frame_count]
"#
            )
        };

        let mut backend_a = MiniBackend::load(&script_with_counter("A"), "dsp_counter_a");
        let mut backend_b = MiniBackend::load(&script_with_counter("B"), "dsp_counter_b");

        backend_a.initialize(1, 4);
        backend_b.initialize(1, 4);

        let input = vec![0.0f32; 4];
        let mut out_a = vec![vec![0.0f32; 4]];
        let mut out_b = vec![vec![0.0f32; 4]];

        // Call A three times
        for _ in 0..3 {
            backend_a.process(&[&input], &mut out_a, 4);
        }
        // Call B once
        backend_b.process(&[&input], &mut out_b, 4);

        assert_eq!(
            out_a[0][0], 3.0,
            "backend A call_count should be 3 (independent)"
        );
        assert_eq!(
            out_b[0][0], 1.0,
            "backend B call_count should be 1 (not contaminated by A)"
        );
    }

    // -----------------------------------------------------------------------
    // Test 3: Concurrent processing from multiple threads
    // -----------------------------------------------------------------------
    #[test]
    fn test_concurrent_processing() {
        setup_python();

        let script_gain = |gain: f32| {
            format!(
                r#"
import numpy as np
def process(inputs, outputs, frame_count, sample_rate):
    for ch in range(len(inputs)):
        outputs[ch][:frame_count] = inputs[ch][:frame_count] * {gain}
"#
            )
        };

        let mut backend_a = MiniBackend::load(&script_gain(0.25), "dsp_thread_a");
        let mut backend_b = MiniBackend::load(&script_gain(4.0), "dsp_thread_b");

        backend_a.initialize(1, 256);
        backend_b.initialize(1, 256);

        let handle_a = std::thread::spawn(move || {
            let input = vec![1.0f32; 256];
            let mut output = vec![vec![0.0f32; 256]];
            for _ in 0..100 {
                backend_a.process(&[&input], &mut output, 256);
            }
            output[0][0]
        });

        let handle_b = std::thread::spawn(move || {
            let input = vec![1.0f32; 256];
            let mut output = vec![vec![0.0f32; 256]];
            for _ in 0..100 {
                backend_b.process(&[&input], &mut output, 256);
            }
            output[0][0]
        });

        let result_a = handle_a.join().expect("thread A panicked");
        let result_b = handle_b.join().expect("thread B panicked");

        assert_eq!(result_a, 0.25, "thread A (gain 0.25)");
        assert_eq!(result_b, 4.0, "thread B (gain 4.0)");
    }

    // -----------------------------------------------------------------------
    // Test 4: Reloading one instance doesn't affect the other
    // -----------------------------------------------------------------------
    #[test]
    fn test_reload_one_doesnt_affect_other() {
        setup_python();

        let script_passthrough = r#"
import numpy as np
def process(inputs, outputs, frame_count, sample_rate):
    for ch in range(len(inputs)):
        outputs[ch][:frame_count] = inputs[ch][:frame_count]
"#;

        let script_silence = r#"
import numpy as np
def process(inputs, outputs, frame_count, sample_rate):
    for ch in range(len(inputs)):
        outputs[ch][:frame_count] = 0.0
"#;

        let mut backend_a = MiniBackend::load(script_passthrough, "dsp_reload_a");
        let mut backend_b = MiniBackend::load(script_passthrough, "dsp_reload_b");

        backend_a.initialize(1, 4);
        backend_b.initialize(1, 4);

        let input = vec![1.0f32, 0.5, -1.0, 0.25];

        // Verify both pass through initially
        let mut out_b = vec![vec![0.0f32; 4]];
        backend_b.process(&[&input], &mut out_b, 4);
        assert_eq!(out_b[0], input, "B should passthrough before A reloads");

        // Reload A with a completely different script (silence)
        backend_a = MiniBackend::load(script_silence, "dsp_reload_a");
        backend_a.initialize(1, 4);

        // Verify B is STILL passthrough (not affected by A's reload)
        let mut out_b2 = vec![vec![0.0f32; 4]];
        backend_b.process(&[&input], &mut out_b2, 4);
        assert_eq!(
            out_b2[0], input,
            "B should STILL passthrough after A reloaded to silence"
        );

        // Verify A is now silence
        let mut out_a = vec![vec![99.0f32; 4]];
        backend_a.process(&[&input], &mut out_a, 4);
        assert_eq!(out_a[0], vec![0.0, 0.0, 0.0, 0.0], "A should output silence");
    }

    // -----------------------------------------------------------------------
    // Test 5: Demonstrate shared module name collision (the current bug),
    //         then show unique names fix it
    // -----------------------------------------------------------------------
    #[test]
    fn test_shared_module_name_collision() {
        setup_python();

        let script_a = r#"
import numpy as np
INSTANCE_MARKER = "I_AM_SCRIPT_A"
def process(inputs, outputs, frame_count, sample_rate):
    for ch in range(len(inputs)):
        outputs[ch][:frame_count] = inputs[ch][:frame_count] * 0.5
"#;

        let script_b = r#"
import numpy as np
INSTANCE_MARKER = "I_AM_SCRIPT_B"
def process(inputs, outputs, frame_count, sample_rate):
    for ch in range(len(inputs)):
        outputs[ch][:frame_count] = inputs[ch][:frame_count] * 2.0
"#;

        // --- Part 1: Show the collision with shared module name ---
        let _backend_a_shared = MiniBackend::load(script_a, "dsp_script");

        let marker_after_a = Python::with_gil(|py| -> String {
            let sys = py.import("sys").unwrap();
            let modules = sys.getattr("modules").unwrap();
            let module = modules.get_item("dsp_script").unwrap();
            module
                .getattr("INSTANCE_MARKER")
                .unwrap()
                .extract()
                .unwrap()
        });
        assert_eq!(marker_after_a, "I_AM_SCRIPT_A");

        // Load B as "dsp_script" — this POPS the old module first
        let _backend_b_shared = MiniBackend::load(script_b, "dsp_script");

        // sys.modules["dsp_script"] now points to B's module
        let marker_after_b = Python::with_gil(|py| -> String {
            let sys = py.import("sys").unwrap();
            let modules = sys.getattr("modules").unwrap();
            let module = modules.get_item("dsp_script").unwrap();
            module
                .getattr("INSTANCE_MARKER")
                .unwrap()
                .extract()
                .unwrap()
        });
        assert_eq!(
            marker_after_b, "I_AM_SCRIPT_B",
            "sys.modules['dsp_script'] was overwritten by B's load — collision!"
        );

        // A's process_fn still works (it holds a Py<PyAny> ref to the old module object),
        // but sys.modules no longer points to A's module. Any code that looks up
        // "dsp_script" in sys.modules would get B's version.

        // --- Part 2: Show unique names prevent the collision ---
        let _backend_a_unique = MiniBackend::load(script_a, "dsp_unique_0");
        let _backend_b_unique = MiniBackend::load(script_b, "dsp_unique_1");

        let (marker_a, marker_b) = Python::with_gil(|py| -> (String, String) {
            let sys = py.import("sys").unwrap();
            let modules = sys.getattr("modules").unwrap();
            let mod_a = modules.get_item("dsp_unique_0").unwrap();
            let mod_b = modules.get_item("dsp_unique_1").unwrap();
            (
                mod_a
                    .getattr("INSTANCE_MARKER")
                    .unwrap()
                    .extract()
                    .unwrap(),
                mod_b
                    .getattr("INSTANCE_MARKER")
                    .unwrap()
                    .extract()
                    .unwrap(),
            )
        });

        assert_eq!(marker_a, "I_AM_SCRIPT_A", "unique name: A preserved");
        assert_eq!(marker_b, "I_AM_SCRIPT_B", "unique name: B preserved");
    }
}
