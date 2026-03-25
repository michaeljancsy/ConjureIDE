use crate::backend::Backend;
use crate::params::PARAM_COUNT;
use crate::python_backend::PythonBackend;
use crate::ring_buffer::AudioRingBuffer;
use crate::wasm_backend::WasmBackend;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::Mutex;

/// Demo limit in seconds. The actual sample count is computed from the host sample rate
/// at `initialize()` time so the demo period is consistent regardless of sample rate.
/// Only buffers with output peak >= DEMO_SILENCE_THRESHOLD count toward this limit,
/// so idle time (no audio playing) does not consume the demo period.
const DEMO_LIMIT_SECONDS: f64 = 60.0;

/// Silence threshold for demo gating: ~-60 dB.
/// Output buffers with peak amplitude below this are considered silent
/// and do not count against the demo time limit.
const DEMO_SILENCE_THRESHOLD: f32 = 0.001;

/// Real-time audio DSP kernel with pluggable processing backends.
///
/// Supports Python scripts (via pyo3/numpy) and WASM modules (via wasmtime).
/// When a backend is loaded, `process()` delegates to it. When no backend
/// is loaded or the backend errors, the kernel falls back to passthrough.
///
/// Thread safety: The `backend` field is wrapped in a `Mutex` to prevent
/// use-after-free when the main thread swaps backends while the render thread
/// is processing. The render thread uses `try_lock()` (never blocks — falls
/// back to passthrough if the lock is held during a swap).
pub struct DSPKernel {
    sample_rate: f64,
    bypassed: bool,
    max_frames_to_render: u32,
    channel_count: usize,
    backend: Mutex<Option<Box<dyn Backend>>>,
    pub(crate) last_error: Option<String>,
    /// 16 generic parameters (0.0–1.0), stored as AtomicU32 via f32::to_bits/from_bits.
    /// Main thread writes (DAW automation), audio thread reads — lock-free via Relaxed ordering.
    params: [AtomicU32; PARAM_COUNT],
    /// Lock-free ring buffers for spectrogram visualization.
    /// Audio thread writes mono-downmixed samples; UI thread reads for FFT.
    input_ring: AudioRingBuffer,
    output_ring: AudioRingBuffer,
    /// When false, ring buffers are not written to (saves CPU when spectrogram is hidden).
    /// UI thread sets this via `set_capture_enabled`; audio thread checks before writing.
    capture_enabled: AtomicBool,
    /// Scratch buffer for mono downmix (avoids per-callback allocation).
    /// Sized to `max_frames_to_render`.
    capture_scratch: Vec<f32>,
    /// Whether a valid license has been verified. Default: false (demo mode).
    /// Main thread writes (after verification), audio thread reads — lock-free.
    licensed: AtomicBool,
    /// Cumulative count of audio samples processed while unlicensed.
    /// Once this reaches `demo_limit_samples`, output is silenced.
    /// Incremented on audio thread, read from UI thread — lock-free.
    demo_samples_processed: AtomicU64,
    /// Sample count equivalent of DEMO_LIMIT_SECONDS at the current sample rate.
    /// Computed in `initialize()` from the host sample rate.
    demo_limit_samples: u64,
    /// Cached JSON representation of script-declared parameter names.
    /// Set after each successful script/WASM load. None means "no names declared."
    /// Pointer returned by `param_names_json_ptr()` is valid until next script load or destroy.
    param_names_json: Option<std::ffi::CString>,
    /// Cached JSON representation of rich parameter metadata (name, min, max, unit, default).
    /// Set after each successful script/WASM load that declares a `PARAMS` dict.
    /// None means "no rich metadata" (backward-compatible mode).
    param_metadata_json: Option<std::ffi::CString>,
}

impl DSPKernel {
    pub fn new() -> Self {
        const ZERO: AtomicU32 = AtomicU32::new(0);
        Self {
            sample_rate: 44100.0,
            bypassed: false,
            max_frames_to_render: 1024,
            channel_count: 0,
            backend: Mutex::new(None),
            last_error: None,
            params: [ZERO; PARAM_COUNT],
            input_ring: AudioRingBuffer::new(AudioRingBuffer::DEFAULT_CAPACITY),
            output_ring: AudioRingBuffer::new(AudioRingBuffer::DEFAULT_CAPACITY),
            capture_enabled: AtomicBool::new(false),
            capture_scratch: vec![0.0; 1024],
            licensed: AtomicBool::new(false),
            demo_samples_processed: AtomicU64::new(0),
            demo_limit_samples: (DEMO_LIMIT_SECONDS * 44100.0) as u64,
            param_names_json: None,
            param_metadata_json: None,
        }
    }

    pub fn initialize(&mut self, input_channels: i32, _output_channels: i32, sample_rate: f64) {
        self.sample_rate = sample_rate;
        self.channel_count = input_channels as usize;
        self.demo_limit_samples = (DEMO_LIMIT_SECONDS * sample_rate) as u64;

        if let Ok(mut guard) = self.backend.lock() {
            if let Some(backend) = guard.as_mut() {
                backend.initialize(self.channel_count, sample_rate, self.max_frames_to_render);
            }
        }
    }

    pub fn deinitialize(&mut self) {
        if let Ok(mut guard) = self.backend.lock() {
            if let Some(backend) = guard.as_mut() {
                backend.deinitialize();
            }
        }
    }

    /// Load a Python script containing a `process()` function.
    /// `python_home` sets PYTHONHOME before interpreter init.
    /// Returns true on success.
    pub fn load_script(&mut self, python_home: &str, script_path: &str) -> bool {
        match PythonBackend::load(python_home, script_path) {
            Ok(mut pb) => {
                // If already initialized with channels, allocate arrays now
                if self.channel_count > 0 {
                    pb.initialize(self.channel_count, self.sample_rate, self.max_frames_to_render);
                }
                let names = pb.param_names();
                let metadata = pb.param_metadata().map(|m| m.to_vec());
                // Lock to swap — render thread will passthrough during this brief window
                if let Ok(mut guard) = self.backend.lock() {
                    *guard = Some(Box::new(pb));
                }
                self.update_param_names_cache(names);
                self.update_param_metadata_cache(metadata);
                self.last_error = None;
                true
            }
            Err(err_msg) => {
                self.last_error = Some(err_msg);
                false
            }
        }
    }

    /// Load a WASM module for DSP processing.
    /// The module must export a `process` function and `memory`.
    /// Returns true on success.
    pub fn load_wasm(&mut self, wasm_bytes: &[u8]) -> bool {
        match WasmBackend::load(wasm_bytes) {
            Ok(mut wb) => {
                if self.channel_count > 0 {
                    wb.initialize(self.channel_count, self.sample_rate, self.max_frames_to_render);
                }
                let names = wb.param_names();
                let metadata = wb.param_metadata().map(|m| m.to_vec());
                // Lock to swap — render thread will passthrough during this brief window
                if let Ok(mut guard) = self.backend.lock() {
                    *guard = Some(Box::new(wb));
                }
                self.update_param_names_cache(names);
                self.update_param_metadata_cache(metadata);
                self.last_error = None;
                true
            }
            Err(err_msg) => {
                self.last_error = Some(err_msg);
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

    /// Set a parameter value. Addresses are 0-based (0–7).
    /// Called from the main thread (DAW automation).
    pub fn set_parameter(&self, address: u64, value: f32) {
        if (address as usize) < PARAM_COUNT {
            self.params[address as usize].store(value.to_bits(), Ordering::Relaxed);
        }
    }

    /// Get a parameter value. Addresses are 0-based (0–7).
    pub fn get_parameter(&self, address: u64) -> f32 {
        if (address as usize) < PARAM_COUNT {
            f32::from_bits(self.params[address as usize].load(Ordering::Relaxed))
        } else {
            0.0
        }
    }

    /// Snapshot all parameter values into a stack array for the audio thread.
    fn snapshot_params(&self) -> [f32; PARAM_COUNT] {
        let mut out = [0.0f32; PARAM_COUNT];
        for i in 0..PARAM_COUNT {
            out[i] = f32::from_bits(self.params[i].load(Ordering::Relaxed));
        }
        out
    }

    pub fn maximum_frames_to_render(&self) -> u32 {
        self.max_frames_to_render
    }

    pub fn set_maximum_frames_to_render(&mut self, max_frames: u32) {
        self.max_frames_to_render = max_frames;
        // Resize scratch buffer to match (no allocation on audio thread)
        self.capture_scratch.resize(max_frames as usize, 0.0);
    }

    /// Enable or disable audio capture for spectrogram visualization.
    /// Called from the UI thread. When disabled, the audio thread skips
    /// writing to ring buffers.
    pub fn set_capture_enabled(&self, enabled: bool) {
        self.capture_enabled.store(enabled, Ordering::Relaxed);
        if !enabled {
            self.input_ring.clear();
            self.output_ring.clear();
        }
    }

    /// Check if capture is enabled.
    pub fn is_capture_enabled(&self) -> bool {
        self.capture_enabled.load(Ordering::Relaxed)
    }

    /// Read available samples from the input ring buffer into `output`.
    /// Returns the number of samples actually read. Called from UI thread.
    pub fn read_input_ring(&self, output: &mut [f32]) -> usize {
        self.input_ring.read(output)
    }

    /// Read available samples from the output ring buffer into `output`.
    /// Returns the number of samples actually read. Called from UI thread.
    pub fn read_output_ring(&self, output: &mut [f32]) -> usize {
        self.output_ring.read(output)
    }

    /// Set the licensed state. Called from the main thread after verification.
    /// Resets the demo counter when licensing (so re-licensing works cleanly).
    pub fn set_licensed(&self, licensed: bool) {
        self.licensed.store(licensed, Ordering::Relaxed);
        if licensed {
            self.demo_samples_processed.store(0, Ordering::Relaxed);
        }
    }

    /// Check if the kernel is licensed.
    pub fn is_licensed(&self) -> bool {
        self.licensed.load(Ordering::Relaxed)
    }

    /// Returns the approximate seconds of demo time remaining at the given sample rate.
    /// Returns infinity if licensed.
    pub fn demo_seconds_remaining(&self, sample_rate: f64) -> f64 {
        if self.is_licensed() {
            return f64::INFINITY;
        }
        let processed = self.demo_samples_processed.load(Ordering::Relaxed);
        let remaining = self.demo_limit_samples.saturating_sub(processed);
        remaining as f64 / sample_rate
    }

    /// Reset the demo sample counter to zero, giving another 60 seconds of demo time.
    pub fn reset_demo(&self) {
        self.demo_samples_processed.store(0, Ordering::Relaxed);
    }

    /// Mono-downmix multi-channel audio into the scratch buffer and write to ring buffer.
    /// Called from the audio thread during process().
    unsafe fn capture_to_ring(
        &self,
        buffers: &[*const f32],
        channel_count: usize,
        frame_count: usize,
        ring: &AudioRingBuffer,
    ) {
        let scratch = self.capture_scratch.as_ptr() as *mut f32;
        let count = frame_count.min(self.capture_scratch.len());

        if channel_count == 1 {
            // Mono: copy directly
            let src = std::slice::from_raw_parts(buffers[0], count);
            std::ptr::copy_nonoverlapping(src.as_ptr(), scratch, count);
        } else {
            // Multi-channel: sum and divide
            let inv_channels = 1.0 / channel_count as f32;
            for i in 0..count {
                let mut sum = 0.0f32;
                for ch in 0..channel_count {
                    sum += *buffers[ch].add(i);
                }
                *scratch.add(i) = sum * inv_channels;
            }
        }

        let mono_slice = std::slice::from_raw_parts(scratch, count);
        ring.write(mono_slice);
    }

    /// Returns the last error message, if any.
    pub fn last_error(&self) -> Option<&str> {
        self.last_error.as_deref()
    }

    /// Update the cached JSON representation of parameter names.
    fn update_param_names_cache(&mut self, names: std::collections::HashMap<u8, String>) {
        if names.is_empty() {
            self.param_names_json = None;
        } else {
            // Use BTreeMap for sorted keys in JSON output
            let map: std::collections::BTreeMap<String, String> = names
                .into_iter()
                .map(|(k, v)| (k.to_string(), v))
                .collect();
            self.param_names_json = serde_json::to_string(&map)
                .ok()
                .and_then(|s| std::ffi::CString::new(s).ok());
        }
    }

    /// Returns a pointer to the cached parameter names JSON, or null if none declared.
    /// The pointer is valid until the next script load or kernel destroy.
    pub fn param_names_json_ptr(&self) -> *const std::os::raw::c_char {
        match &self.param_names_json {
            Some(cstr) => cstr.as_ptr(),
            None => std::ptr::null(),
        }
    }

    /// Update the cached JSON for rich parameter metadata.
    /// Also sets kernel parameter defaults from the metadata.
    fn update_param_metadata_cache(&mut self, metadata: Option<Vec<crate::params::ParamMetadata>>) {
        match metadata {
            Some(meta) if !meta.is_empty() => {
                // Set default values in the kernel (normalized 0–1)
                for (i, m) in meta.iter().enumerate() {
                    if i < PARAM_COUNT {
                        let normalized = m.normalize(m.default);
                        self.params[i].store(normalized.to_bits(), Ordering::Relaxed);
                    }
                }
                self.param_metadata_json = serde_json::to_string(&meta)
                    .ok()
                    .and_then(|s| std::ffi::CString::new(s).ok());
            }
            _ => {
                self.param_metadata_json = None;
            }
        }
    }

    /// Returns a pointer to the cached parameter metadata JSON, or null if none declared.
    /// The pointer is valid until the next script load or kernel destroy.
    pub fn param_metadata_json_ptr(&self) -> *const std::os::raw::c_char {
        match &self.param_metadata_json {
            Some(cstr) => cstr.as_ptr(),
            None => std::ptr::null(),
        }
    }

    /// Capture any backend error into `last_error` so it outlives the mutex guard.
    fn capture_backend_error(&mut self) {
        if let Ok(guard) = self.backend.lock() {
            if let Some(ref backend) = *guard {
                if let Some(err) = backend.last_error() {
                    self.last_error = Some(err.to_string());
                }
            }
        }
    }

    /// Benchmark the process function with a 440 Hz sine wave.
    /// Returns the max execution time in seconds over 5 runs (after 1 warm-up),
    /// or None if no backend is loaded.
    pub fn benchmark_process(&mut self) -> Option<f64> {
        {
            let guard = self.backend.lock().ok()?;
            if guard.is_none() {
                return None;
            }
        }

        let channel_count = if self.channel_count > 0 {
            self.channel_count
        } else {
            2
        };
        let frame_count = self.max_frames_to_render as usize;

        // Temporarily initialize backend if needed
        let needs_temp_init = self.channel_count == 0;
        if needs_temp_init {
            if let Ok(mut guard) = self.backend.lock() {
                if let Some(backend) = guard.as_mut() {
                    backend.initialize(channel_count, self.sample_rate, self.max_frames_to_render);
                }
            }
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
                    .map(|i| {
                        (2.0 * std::f32::consts::PI * 440.0 * i as f32 / sample_rate as f32).sin()
                    })
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

        // Clean up temp init
        if needs_temp_init {
            if let Ok(mut guard) = self.backend.lock() {
                if let Some(backend) = guard.as_mut() {
                    backend.deinitialize();
                }
            }
        }

        Some(max_time)
    }

    /// Process audio buffers. Called from the real-time audio thread.
    ///
    /// Delegates to the loaded backend (Python or WASM). Falls back to
    /// passthrough (copy input to output) when bypassed, no backend is
    /// loaded, or the backend errors at runtime.
    ///
    /// # Safety
    /// - `input_buffers` must point to `channel_count` valid `*const f32` pointers.
    /// - `output_buffers` must point to `channel_count` valid `*mut f32` pointers.
    /// - Each channel buffer must contain at least `frame_count` samples.
    pub unsafe fn process(
        &mut self,
        input_buffers: *const *const f32,
        output_buffers: *const *mut f32,
        channel_count: u32,
        frame_count: u32,
    ) {
        let channel_count = channel_count as usize;
        let frame_count = frame_count as usize;
        let inputs = std::slice::from_raw_parts(input_buffers, channel_count);
        let outputs = std::slice::from_raw_parts(output_buffers, channel_count);

        let capturing = self.capture_enabled.load(Ordering::Relaxed);

        // Capture input audio for spectrogram (before processing)
        if capturing {
            self.capture_to_ring(inputs, channel_count, frame_count, &self.input_ring);
        }

        if self.bypassed {
            Self::passthrough(inputs, outputs, channel_count, frame_count);
            // Capture output (same as input during bypass)
            if capturing {
                self.capture_to_ring(inputs, channel_count, frame_count, &self.output_ring);
            }
            // Bypass does NOT count against demo time
            return;
        }

        // Demo mode gate: if unlicensed and demo time exhausted, output silence.
        if !self.licensed.load(Ordering::Relaxed) {
            let processed = self.demo_samples_processed.load(Ordering::Relaxed);
            if processed >= self.demo_limit_samples {
                // Zero all output buffers
                for ch in 0..channel_count {
                    let dst = std::slice::from_raw_parts_mut(outputs[ch], frame_count);
                    for sample in dst.iter_mut() {
                        *sample = 0.0;
                    }
                }
                if capturing {
                    let out_as_const: Vec<*const f32> =
                        outputs.iter().map(|p| *p as *const f32).collect();
                    self.capture_to_ring(
                        &out_as_const,
                        channel_count,
                        frame_count,
                        &self.output_ring,
                    );
                }
                return;
            }
        }

        // Snapshot parameters once per callback (lock-free atomic reads)
        let params = self.snapshot_params();

        // Try backend processing — use try_lock to never block the render thread.
        // If the main thread is swapping backends, we fall through to passthrough.
        if let Ok(mut guard) = self.backend.try_lock() {
            if let Some(ref mut backend) = *guard {
                if backend.process(inputs, outputs, channel_count, frame_count, self.sample_rate, &params) {
                    Self::safety_clamp(outputs, channel_count, frame_count);
                    // Cast output pointers to const (used for capture and demo gating)
                    let out_as_const: Vec<*const f32> = outputs.iter().map(|p| *p as *const f32).collect();
                    // Capture output audio for spectrogram (after processing)
                    if capturing {
                        self.capture_to_ring(&out_as_const, channel_count, frame_count, &self.output_ring);
                    }
                    // Increment demo counter only if output is non-silent
                    if !self.licensed.load(Ordering::Relaxed)
                        && Self::buffer_peak(&out_as_const, channel_count, frame_count)
                            >= DEMO_SILENCE_THRESHOLD
                    {
                        self.demo_samples_processed
                            .fetch_add(frame_count as u64, Ordering::Relaxed);
                    }
                    return;
                }
                // Backend failed — capture error before dropping guard
                if let Some(err) = backend.last_error() {
                    self.last_error = Some(err.to_string());
                }
            }
        }

        // Fallback: passthrough (copy input to output unchanged)
        Self::passthrough(inputs, outputs, channel_count, frame_count);
        // Capture output (same as input during passthrough)
        if capturing {
            self.capture_to_ring(inputs, channel_count, frame_count, &self.output_ring);
        }
        // Increment demo counter only if output is non-silent
        if !self.licensed.load(Ordering::Relaxed) {
            let out_as_const: Vec<*const f32> =
                outputs.iter().map(|p| *p as *const f32).collect();
            if Self::buffer_peak(&out_as_const, channel_count, frame_count)
                >= DEMO_SILENCE_THRESHOLD
            {
                self.demo_samples_processed
                    .fetch_add(frame_count as u64, Ordering::Relaxed);
            }
        }
    }

    /// Clamp all output samples to [-1.0, 1.0] to prevent dangerously loud output.
    unsafe fn safety_clamp(
        outputs: &[*mut f32],
        channel_count: usize,
        frame_count: usize,
    ) {
        for ch in 0..channel_count {
            let dst = std::slice::from_raw_parts_mut(outputs[ch], frame_count);
            for sample in dst.iter_mut() {
                *sample = sample.clamp(-1.0, 1.0);
            }
        }
    }

    /// Compute the peak absolute sample value across all channels.
    /// Used for demo silence gating — returns 0.0 for empty buffers.
    unsafe fn buffer_peak(buffers: &[*const f32], channel_count: usize, frame_count: usize) -> f32 {
        let mut peak: f32 = 0.0;
        for ch in 0..channel_count {
            let buf = std::slice::from_raw_parts(buffers[ch], frame_count);
            for &sample in buf {
                let abs = sample.abs();
                if abs > peak {
                    peak = abs;
                }
            }
        }
        peak
    }

    /// Copy input to output unchanged.
    unsafe fn passthrough(
        inputs: &[*const f32],
        outputs: &[*mut f32],
        channel_count: usize,
        frame_count: usize,
    ) {
        for ch in 0..channel_count {
            let src = std::slice::from_raw_parts(inputs[ch], frame_count);
            let dst = std::slice::from_raw_parts_mut(outputs[ch], frame_count);
            dst.copy_from_slice(src);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // --- Helper ---

    /// Demo limit in samples at 48kHz (the sample rate used in tests).
    const TEST_DEMO_LIMIT_SAMPLES: u64 = (DEMO_LIMIT_SECONDS * 48000.0) as u64;

    /// Returns (python_home, script_path) for integration tests.
    /// Returns None if the bundled Python runtime hasn't been set up.
    fn test_python_paths() -> Option<(String, String)> {
        let manifest_dir = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        let python_home = manifest_dir.join("../python-dist");
        let script_path = manifest_dir.join("../../ConjureDSPExtension/Resources/process.py");
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
        assert!(kernel.param_names_json_ptr().is_null());
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
        let mut kernel = DSPKernel::new(); // not bypassed, no script loaded

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
        let mut kernel = DSPKernel::new();

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
            unsafe {
                kernel.process(&ip, &op, 1, 4);
            }
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
        let mut kernel = DSPKernel::new();
        let input: [f32; 1] = [0.75];
        let mut output: [f32; 1] = [0.0];
        let ip: *const f32 = input.as_ptr();
        let op: *mut f32 = output.as_mut_ptr();
        unsafe {
            kernel.process(&ip, &op, 1, 1);
        }
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
        unsafe {
            kernel.process(&ip, &op, 1, 4096);
        }
        assert!(output.iter().all(|&s| s == 0.5));
    }

    #[test]
    fn test_initialize_changes_channel_count() {
        let mut kernel = DSPKernel::new();
        kernel.initialize(1, 1, 44100.0);
        assert_eq!(kernel.channel_count, 1);
        kernel.deinitialize();
        kernel.initialize(2, 2, 48000.0);
        assert_eq!(kernel.channel_count, 2);
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
        unsafe {
            kernel.process(&ip, &op, 1, 4);
        }
        assert_eq!(output, [1.0, 0.5, -1.0, 0.0]);

        // Process with bypass off (still passthrough, no script)
        kernel.set_bypassed(false);
        output = [0.0; 4];
        unsafe {
            kernel.process(&ip, &op, 1, 4);
        }
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

        // process.py applies gain from params["gain"], default 0 dB = unity gain
        assert_eq!(output, [1.0, 0.5, -1.0, 0.0]);
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

        // process.py applies gain from params["gain"], default 0 dB = unity gain
        assert_eq!(output_l, [1.0, 0.5, -1.0, 0.0]);
        assert_eq!(output_r, [0.2, 0.4, 0.6, 0.8]);
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
            None => {
                eprintln!("Skipping: bundled Python runtime not found");
                return;
            }
        };
        let script = write_temp_script(
            "import numpy as np\ndef process(inputs, outputs, frame_count, sample_rate):\n    raise RuntimeError('intentional error')\n",
        );
        let mut kernel = DSPKernel::new();
        assert!(kernel.load_script(&python_home, script.to_str().unwrap()));
        kernel.initialize(1, 1, 44100.0);

        let input: [f32; 4] = [1.0, 0.5, -1.0, 0.0];
        let mut output: [f32; 4] = [0.0; 4];
        let ip: *const f32 = input.as_ptr();
        let op: *mut f32 = output.as_mut_ptr();
        unsafe {
            kernel.process(&ip, &op, 1, 4);
        }
        assert_eq!(output, [1.0, 0.5, -1.0, 0.0]);
        std::fs::remove_file(script).ok();
    }

    #[test]
    fn test_process_after_python_error_continues_working() {
        let (python_home, _) = match test_python_paths() {
            Some(paths) => paths,
            None => {
                eprintln!("Skipping: bundled Python runtime not found");
                return;
            }
        };
        let script = write_temp_script(
            "import numpy as np\ndef process(inputs, outputs, frame_count, sr):\n    raise ValueError('boom')\n",
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
            unsafe {
                kernel.process(&ip, &op, 1, 4);
            }
            assert_eq!(output, [0.7, 0.7, 0.7, 0.7]);
        }
        std::fs::remove_file(script).ok();
    }

    #[test]
    fn test_script_hot_reload() {
        let (python_home, _) = match test_python_paths() {
            Some(paths) => paths,
            None => {
                eprintln!("Skipping: bundled Python runtime not found");
                return;
            }
        };
        let script_half = write_temp_script(
            "import numpy as np\ndef process(inputs, outputs, frame_count, sr):\n    for ch in range(len(inputs)):\n        outputs[ch][:frame_count] = inputs[ch][:frame_count] * 0.5\n",
        );
        let mut kernel = DSPKernel::new();
        assert!(kernel.load_script(&python_home, script_half.to_str().unwrap()));
        kernel.initialize(1, 1, 44100.0);

        let input: [f32; 4] = [1.0, 1.0, 1.0, 1.0];
        let mut output: [f32; 4] = [0.0; 4];
        let ip: *const f32 = input.as_ptr();
        let op: *mut f32 = output.as_mut_ptr();
        unsafe {
            kernel.process(&ip, &op, 1, 4);
        }
        assert_eq!(output, [0.5, 0.5, 0.5, 0.5]);

        // Hot-reload with a different gain
        let script_quarter = write_temp_script(
            "import numpy as np\ndef process(inputs, outputs, frame_count, sr):\n    for ch in range(len(inputs)):\n        outputs[ch][:frame_count] = inputs[ch][:frame_count] * 0.25\n",
        );
        assert!(kernel.load_script(&python_home, script_quarter.to_str().unwrap()));
        kernel.initialize(1, 1, 44100.0);

        output = [0.0; 4];
        unsafe {
            kernel.process(&ip, &op, 1, 4);
        }
        assert_eq!(output, [0.25, 0.25, 0.25, 0.25]);

        std::fs::remove_file(script_half).ok();
        std::fs::remove_file(script_quarter).ok();
    }

    #[test]
    fn test_load_script_missing_process_function() {
        let (python_home, _) = match test_python_paths() {
            Some(paths) => paths,
            None => {
                eprintln!("Skipping: bundled Python runtime not found");
                return;
            }
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
            None => {
                eprintln!("Skipping: bundled Python runtime not found");
                return;
            }
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
            None => {
                eprintln!("Skipping: bundled Python runtime not found");
                return;
            }
        };
        let script =
            write_temp_script("import nonexistent_module_xyz\ndef process(i,o,f,s): pass\n");
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
            None => {
                eprintln!("Skipping: bundled Python runtime not found");
                return;
            }
        };
        let mut kernel = DSPKernel::new();
        assert!(kernel.load_script(&python_home, &script_path));
        kernel.initialize(2, 2, 44100.0);

        let result = kernel.benchmark_process();
        assert!(result.is_some());
        let time = result.unwrap();
        assert!(time > 0.0, "Benchmark time should be positive, got {}", time);
    }

    // --- WASM integration tests ---

    fn gain_half_wasm() -> Vec<u8> {
        wat::parse_str(r#"
            (module
              (memory (export "memory") 1)
              (func (export "process") (param $in i32) (param $out i32) (param $ch i32) (param $frames i32) (param $sr f32)
                (local $i i32)
                (local $total i32)
                (local.set $total (i32.mul (local.get $ch) (local.get $frames)))
                (block $break
                  (loop $loop
                    (br_if $break (i32.ge_u (local.get $i) (local.get $total)))
                    (f32.store
                      (i32.add (local.get $out) (i32.mul (local.get $i) (i32.const 4)))
                      (f32.mul
                        (f32.load (i32.add (local.get $in) (i32.mul (local.get $i) (i32.const 4))))
                        (f32.const 0.5)
                      )
                    )
                    (local.set $i (i32.add (local.get $i) (i32.const 1)))
                    (br $loop)
                  )
                )
              )
            )
        "#).expect("Failed to parse WAT")
    }

    #[test]
    fn test_load_wasm_and_process() {
        let wasm = gain_half_wasm();
        let mut kernel = DSPKernel::new();
        assert!(kernel.load_wasm(&wasm));
        kernel.initialize(1, 1, 44100.0);

        let input: [f32; 4] = [1.0, 0.5, -1.0, 0.0];
        let mut output: [f32; 4] = [0.0; 4];
        let ip: *const f32 = input.as_ptr();
        let op: *mut f32 = output.as_mut_ptr();

        unsafe { kernel.process(&ip, &op, 1, 4); }
        assert_eq!(output, [0.5, 0.25, -0.5, 0.0]);
    }

    #[test]
    fn test_load_wasm_stereo() {
        let wasm = gain_half_wasm();
        let mut kernel = DSPKernel::new();
        assert!(kernel.load_wasm(&wasm));
        kernel.initialize(2, 2, 44100.0);

        let input_l: [f32; 4] = [1.0, 0.5, -1.0, 0.0];
        let input_r: [f32; 4] = [0.0, -0.5, 1.0, 0.25];
        let mut output_l: [f32; 4] = [0.0; 4];
        let mut output_r: [f32; 4] = [0.0; 4];

        let input_ptrs: [*const f32; 2] = [input_l.as_ptr(), input_r.as_ptr()];
        let output_ptrs: [*mut f32; 2] = [output_l.as_mut_ptr(), output_r.as_mut_ptr()];

        unsafe { kernel.process(input_ptrs.as_ptr(), output_ptrs.as_ptr(), 2, 4); }
        assert_eq!(output_l, [0.5, 0.25, -0.5, 0.0]);
        assert_eq!(output_r, [0.0, -0.25, 0.5, 0.125]);
    }

    #[test]
    fn test_load_wasm_invalid() {
        let mut kernel = DSPKernel::new();
        assert!(!kernel.load_wasm(&[0xFF, 0xFF, 0xFF, 0xFF]));
        assert!(kernel.last_error().is_some());
    }

    #[test]
    fn test_wasm_benchmark() {
        let wasm = gain_half_wasm();
        let mut kernel = DSPKernel::new();
        assert!(kernel.load_wasm(&wasm));
        kernel.initialize(1, 1, 44100.0);

        let result = kernel.benchmark_process();
        assert!(result.is_some());
        assert!(result.unwrap() > 0.0);
    }

    #[test]
    fn test_wasm_bypass() {
        let wasm = gain_half_wasm();
        let mut kernel = DSPKernel::new();
        assert!(kernel.load_wasm(&wasm));
        kernel.initialize(1, 1, 44100.0);
        kernel.set_bypassed(true);

        let input: [f32; 4] = [1.0, 0.5, -1.0, 0.0];
        let mut output: [f32; 4] = [0.0; 4];
        let ip: *const f32 = input.as_ptr();
        let op: *mut f32 = output.as_mut_ptr();

        unsafe { kernel.process(&ip, &op, 1, 4); }
        // Bypass should passthrough unchanged, not apply 0.5x gain
        assert_eq!(output, [1.0, 0.5, -1.0, 0.0]);
    }

    #[test]
    fn test_hot_reload_wasm_replaces_wasm() {
        let wasm = gain_half_wasm();
        let passthrough_wasm = wat::parse_str(r#"
            (module
              (memory (export "memory") 1)
              (func (export "process") (param $in i32) (param $out i32) (param $ch i32) (param $frames i32) (param $sr f32)
                (local $i i32)
                (local $total i32)
                (local.set $total (i32.mul (local.get $ch) (local.get $frames)))
                (block $break
                  (loop $loop
                    (br_if $break (i32.ge_u (local.get $i) (local.get $total)))
                    (f32.store
                      (i32.add (local.get $out) (i32.mul (local.get $i) (i32.const 4)))
                      (f32.load (i32.add (local.get $in) (i32.mul (local.get $i) (i32.const 4))))
                    )
                    (local.set $i (i32.add (local.get $i) (i32.const 1)))
                    (br $loop)
                  )
                )
              )
            )
        "#).expect("Failed to parse WAT");

        let mut kernel = DSPKernel::new();

        // Load gain-half WASM
        assert!(kernel.load_wasm(&wasm));
        kernel.initialize(1, 1, 44100.0);

        let input: [f32; 4] = [1.0, 0.5, -1.0, 0.0];
        let mut output: [f32; 4] = [0.0; 4];
        let ip: *const f32 = input.as_ptr();
        let op: *mut f32 = output.as_mut_ptr();

        unsafe { kernel.process(&ip, &op, 1, 4); }
        assert_eq!(output, [0.5, 0.25, -0.5, 0.0]);

        // Hot-reload to passthrough WASM
        assert!(kernel.load_wasm(&passthrough_wasm));

        output = [0.0; 4];
        unsafe { kernel.process(&ip, &op, 1, 4); }
        assert_eq!(output, [1.0, 0.5, -1.0, 0.0]);
    }

    #[test]
    fn test_hot_reload_python_to_wasm() {
        let (python_home, script_path) = match test_python_paths() {
            Some(paths) => paths,
            None => {
                eprintln!("Skipping: bundled Python runtime not found");
                return;
            }
        };
        let wasm = gain_half_wasm();
        let mut kernel = DSPKernel::new();

        // Load Python first
        assert!(kernel.load_script(&python_home, &script_path));
        kernel.initialize(1, 1, 44100.0);

        // Hot-reload to WASM
        assert!(kernel.load_wasm(&wasm));

        let input: [f32; 4] = [1.0, 0.5, -1.0, 0.0];
        let mut output: [f32; 4] = [0.0; 4];
        let ip: *const f32 = input.as_ptr();
        let op: *mut f32 = output.as_mut_ptr();

        unsafe { kernel.process(&ip, &op, 1, 4); }
        assert_eq!(output, [0.5, 0.25, -0.5, 0.0]);
    }

    // --- Safety limiter tests ---

    fn gain_10x_wasm() -> Vec<u8> {
        wat::parse_str(r#"
            (module
              (memory (export "memory") 1)
              (func (export "process") (param $in i32) (param $out i32) (param $ch i32) (param $frames i32) (param $sr f32)
                (local $i i32)
                (local $total i32)
                (local.set $total (i32.mul (local.get $ch) (local.get $frames)))
                (block $break
                  (loop $loop
                    (br_if $break (i32.ge_u (local.get $i) (local.get $total)))
                    (f32.store
                      (i32.add (local.get $out) (i32.mul (local.get $i) (i32.const 4)))
                      (f32.mul
                        (f32.load (i32.add (local.get $in) (i32.mul (local.get $i) (i32.const 4))))
                        (f32.const 10.0)
                      )
                    )
                    (local.set $i (i32.add (local.get $i) (i32.const 1)))
                    (br $loop)
                  )
                )
              )
            )
        "#).expect("Failed to parse WAT")
    }

    #[test]
    fn test_safety_limiter_clamps_loud_wasm_output() {
        let wasm = gain_10x_wasm();
        let mut kernel = DSPKernel::new();
        assert!(kernel.load_wasm(&wasm));
        kernel.initialize(1, 1, 44100.0);

        let input: [f32; 4] = [0.5, -0.5, 0.2, -0.2];
        let mut output: [f32; 4] = [0.0; 4];
        let ip: *const f32 = input.as_ptr();
        let op: *mut f32 = output.as_mut_ptr();

        unsafe { kernel.process(&ip, &op, 1, 4); }
        // 10x gain would produce [5.0, -5.0, 2.0, -2.0], clamped to ±1.0
        assert_eq!(output, [1.0, -1.0, 1.0, -1.0]);
    }

    #[test]
    fn test_safety_limiter_clamps_loud_python_output() {
        let (python_home, _) = match test_python_paths() {
            Some(paths) => paths,
            None => {
                eprintln!("Skipping: bundled Python runtime not found");
                return;
            }
        };
        let script = write_temp_script(
            "import numpy as np\ndef process(inputs, outputs, frame_count, sr):\n    for ch in range(len(inputs)):\n        outputs[ch][:frame_count] = inputs[ch][:frame_count] * 10.0\n",
        );
        let mut kernel = DSPKernel::new();
        assert!(kernel.load_script(&python_home, script.to_str().unwrap()));
        kernel.initialize(1, 1, 44100.0);

        let input: [f32; 4] = [0.5, -0.5, 0.2, -0.2];
        let mut output: [f32; 4] = [0.0; 4];
        let ip: *const f32 = input.as_ptr();
        let op: *mut f32 = output.as_mut_ptr();

        unsafe { kernel.process(&ip, &op, 1, 4); }
        // 10x gain clamped to ±1.0
        assert_eq!(output, [1.0, -1.0, 1.0, -1.0]);
        std::fs::remove_file(script).ok();
    }

    #[test]
    fn test_safety_limiter_passes_normal_signal() {
        let wasm = gain_half_wasm();
        let mut kernel = DSPKernel::new();
        assert!(kernel.load_wasm(&wasm));
        kernel.initialize(1, 1, 44100.0);

        let input: [f32; 4] = [0.8, -0.6, 0.4, -0.2];
        let mut output: [f32; 4] = [0.0; 4];
        let ip: *const f32 = input.as_ptr();
        let op: *mut f32 = output.as_mut_ptr();

        unsafe { kernel.process(&ip, &op, 1, 4); }
        // 0.5x gain produces values well within ±1.0, unchanged by limiter
        assert_eq!(output, [0.4, -0.3, 0.2, -0.1]);
    }

    #[test]
    fn test_safety_limiter_does_not_apply_during_bypass() {
        let wasm = gain_10x_wasm();
        let mut kernel = DSPKernel::new();
        assert!(kernel.load_wasm(&wasm));
        kernel.initialize(1, 1, 44100.0);
        kernel.set_bypassed(true);

        // Input with values at ±1.0 — bypass should pass through unchanged
        let input: [f32; 4] = [1.0, -1.0, 0.5, -0.5];
        let mut output: [f32; 4] = [0.0; 4];
        let ip: *const f32 = input.as_ptr();
        let op: *mut f32 = output.as_mut_ptr();

        unsafe { kernel.process(&ip, &op, 1, 4); }
        assert_eq!(output, [1.0, -1.0, 0.5, -0.5]);
    }

    #[test]
    fn test_safety_limiter_stereo() {
        let wasm = gain_10x_wasm();
        let mut kernel = DSPKernel::new();
        assert!(kernel.load_wasm(&wasm));
        kernel.initialize(2, 2, 44100.0);

        let input_l: [f32; 4] = [0.5, -0.5, 0.1, -0.1];
        let input_r: [f32; 4] = [0.3, -0.3, 0.8, -0.8];
        let mut output_l: [f32; 4] = [0.0; 4];
        let mut output_r: [f32; 4] = [0.0; 4];

        let input_ptrs: [*const f32; 2] = [input_l.as_ptr(), input_r.as_ptr()];
        let output_ptrs: [*mut f32; 2] = [output_l.as_mut_ptr(), output_r.as_mut_ptr()];

        unsafe { kernel.process(input_ptrs.as_ptr(), output_ptrs.as_ptr(), 2, 4); }
        // Both channels clamped to ±1.0
        assert_eq!(output_l, [1.0, -1.0, 1.0, -1.0]);
        assert_eq!(output_r, [1.0, -1.0, 1.0, -1.0]);
    }

    #[test]
    fn test_hot_reload_wasm_to_python() {
        let (python_home, script_path) = match test_python_paths() {
            Some(paths) => paths,
            None => {
                eprintln!("Skipping: bundled Python runtime not found");
                return;
            }
        };
        let wasm = gain_half_wasm();
        let mut kernel = DSPKernel::new();

        // Load WASM first
        assert!(kernel.load_wasm(&wasm));
        kernel.initialize(1, 1, 44100.0);

        let input: [f32; 4] = [1.0, 0.5, -1.0, 0.0];
        let mut output: [f32; 4] = [0.0; 4];
        let ip: *const f32 = input.as_ptr();
        let op: *mut f32 = output.as_mut_ptr();

        unsafe { kernel.process(&ip, &op, 1, 4); }
        // WASM applies 0.5x gain
        assert_eq!(output, [0.5, 0.25, -0.5, 0.0]);

        // Hot-reload to Python (process.py applies 0 dB gain = unity)
        assert!(kernel.load_script(&python_home, &script_path));

        output = [0.0; 4];
        unsafe { kernel.process(&ip, &op, 1, 4); }
        assert_eq!(output, [1.0, 0.5, -1.0, 0.0]);
    }

    // --- License & demo mode tests ---

    #[test]
    fn test_new_kernel_is_unlicensed() {
        let kernel = DSPKernel::new();
        assert!(!kernel.is_licensed());
    }

    #[test]
    fn test_license_toggle() {
        let kernel = DSPKernel::new();
        assert!(!kernel.is_licensed());
        kernel.set_licensed(true);
        assert!(kernel.is_licensed());
        kernel.set_licensed(false);
        assert!(!kernel.is_licensed());
    }

    #[test]
    fn test_demo_seconds_remaining_initial() {
        let mut kernel = DSPKernel::new();
        kernel.initialize(1, 1, 48000.0);
        let remaining = kernel.demo_seconds_remaining(48000.0);
        assert!((remaining - 60.0).abs() < 0.1);
    }

    #[test]
    fn test_demo_seconds_remaining_licensed_is_infinite() {
        let kernel = DSPKernel::new();
        kernel.set_licensed(true);
        assert!(kernel.demo_seconds_remaining(48000.0).is_infinite());
    }

    #[test]
    fn test_licensed_kernel_processes_indefinitely() {
        let mut kernel = DSPKernel::new();
        kernel.set_licensed(true);
        kernel.initialize(1, 1, 48000.0);

        let frames = 4096u32;
        // Process well past the demo limit
        let iterations = (TEST_DEMO_LIMIT_SAMPLES / frames as u64) + 100;

        let input = vec![0.5f32; frames as usize];
        let mut output = vec![0.0f32; frames as usize];
        let ip: *const f32 = input.as_ptr();
        let op: *mut f32 = output.as_mut_ptr();

        for _ in 0..iterations {
            unsafe {
                kernel.process(&ip, &op, 1, frames);
            }
        }

        // Output should still be non-zero (passthrough, no backend)
        assert_eq!(output[0], 0.5);
    }

    #[test]
    fn test_unlicensed_kernel_silences_after_limit() {
        let mut kernel = DSPKernel::new();
        assert!(!kernel.is_licensed());
        kernel.initialize(1, 1, 48000.0);

        let frames = 4096u32;
        let iterations_to_exceed = (TEST_DEMO_LIMIT_SAMPLES / frames as u64) + 10;

        let input = vec![0.5f32; frames as usize];
        let mut output = vec![0.0f32; frames as usize];
        let ip: *const f32 = input.as_ptr();
        let op: *mut f32 = output.as_mut_ptr();

        for _ in 0..iterations_to_exceed {
            unsafe {
                kernel.process(&ip, &op, 1, frames);
            }
        }

        // Output should be silence
        assert_eq!(output[0], 0.0);
        assert!(output.iter().all(|&s| s == 0.0));
    }

    #[test]
    fn test_license_toggle_resets_demo_counter() {
        let mut kernel = DSPKernel::new();
        kernel.initialize(1, 1, 48000.0);

        // Process some frames to decrement demo time
        let input = vec![0.5f32; 1024];
        let mut output = vec![0.0f32; 1024];
        let ip: *const f32 = input.as_ptr();
        let op: *mut f32 = output.as_mut_ptr();
        unsafe {
            kernel.process(&ip, &op, 1, 1024);
        }
        assert!(kernel.demo_seconds_remaining(48000.0) < 60.0);

        // License — counter resets
        kernel.set_licensed(true);
        assert!(kernel.demo_seconds_remaining(48000.0).is_infinite());
    }

    #[test]
    fn test_bypass_does_not_count_against_demo() {
        let mut kernel = DSPKernel::new();
        kernel.set_bypassed(true);
        kernel.initialize(1, 1, 48000.0);

        let frames = 4096u32;
        let iterations = (TEST_DEMO_LIMIT_SAMPLES / frames as u64) + 100;

        let input = vec![0.5f32; frames as usize];
        let mut output = vec![0.0f32; frames as usize];
        let ip: *const f32 = input.as_ptr();
        let op: *mut f32 = output.as_mut_ptr();

        for _ in 0..iterations {
            unsafe {
                kernel.process(&ip, &op, 1, frames);
            }
        }

        // Demo counter should still be at 0 (bypass doesn't count)
        let remaining = kernel.demo_seconds_remaining(48000.0);
        assert!((remaining - 60.0).abs() < 0.1);

        // Un-bypass: audio should still work (demo not expired)
        kernel.set_bypassed(false);
        // Re-zero output and get fresh pointer
        for s in output.iter_mut() {
            *s = 0.0;
        }
        unsafe {
            kernel.process(&ip, &op, 1, frames);
        }
        assert_eq!(output[0], 0.5); // passthrough
    }

    #[test]
    fn test_silent_output_does_not_count_against_demo() {
        let mut kernel = DSPKernel::new();
        assert!(!kernel.is_licensed());
        kernel.initialize(1, 1, 48000.0);

        let frames = 4096u32;
        // Process well past the demo limit with silent input (passthrough → silent output)
        let iterations = (TEST_DEMO_LIMIT_SAMPLES / frames as u64) + 100;

        let input = vec![0.0f32; frames as usize];
        let mut output = vec![0.0f32; frames as usize];
        let ip: *const f32 = input.as_ptr();
        let op: *mut f32 = output.as_mut_ptr();

        for _ in 0..iterations {
            unsafe {
                kernel.process(&ip, &op, 1, frames);
            }
        }

        // Demo counter should not have advanced (silent output)
        let remaining = kernel.demo_seconds_remaining(48000.0);
        assert!((remaining - 60.0).abs() < 0.1);
    }

    #[test]
    fn test_below_threshold_does_not_count_against_demo() {
        let mut kernel = DSPKernel::new();
        assert!(!kernel.is_licensed());
        kernel.initialize(1, 1, 48000.0);

        let frames = 1024u32;
        // Input below silence threshold (0.0001 < 0.001)
        let input = vec![0.0001f32; frames as usize];
        let mut output = vec![0.0f32; frames as usize];
        let ip: *const f32 = input.as_ptr();
        let op: *mut f32 = output.as_mut_ptr();

        let iterations = (TEST_DEMO_LIMIT_SAMPLES / frames as u64) + 100;
        for _ in 0..iterations {
            unsafe {
                kernel.process(&ip, &op, 1, frames);
            }
        }

        // Counter should not have advanced
        let remaining = kernel.demo_seconds_remaining(48000.0);
        assert!((remaining - 60.0).abs() < 0.1);
    }

    #[test]
    fn test_above_threshold_counts_against_demo() {
        let mut kernel = DSPKernel::new();
        assert!(!kernel.is_licensed());
        kernel.initialize(1, 1, 48000.0);

        let frames = 1024u32;
        // Input at exactly the threshold
        let input = vec![DEMO_SILENCE_THRESHOLD; frames as usize];
        let mut output = vec![0.0f32; frames as usize];
        let ip: *const f32 = input.as_ptr();
        let op: *mut f32 = output.as_mut_ptr();

        unsafe {
            kernel.process(&ip, &op, 1, frames);
        }

        // Counter should have advanced
        let remaining = kernel.demo_seconds_remaining(48000.0);
        assert!(remaining < 60.0);
    }

    #[test]
    fn test_mixed_silent_and_loud_counts_correctly() {
        let mut kernel = DSPKernel::new();
        assert!(!kernel.is_licensed());
        kernel.initialize(1, 1, 48000.0);

        let frames = 1024u32;
        let silent_input = vec![0.0f32; frames as usize];
        let loud_input = vec![0.5f32; frames as usize];
        let mut output = vec![0.0f32; frames as usize];
        let silent_ip: *const f32 = silent_input.as_ptr();
        let loud_ip: *const f32 = loud_input.as_ptr();
        let op: *mut f32 = output.as_mut_ptr();

        // 10 loud buffers, 10 silent buffers
        for _ in 0..10 {
            unsafe { kernel.process(&loud_ip, &op, 1, frames); }
        }
        for _ in 0..10 {
            unsafe { kernel.process(&silent_ip, &op, 1, frames); }
        }

        // Only 10 * 1024 = 10240 samples should have been counted
        let processed_seconds = 60.0 - kernel.demo_seconds_remaining(48000.0);
        let expected_seconds = (10 * frames as u64) as f64 / 48000.0;
        assert!((processed_seconds - expected_seconds).abs() < 0.01);
    }

    // --- Param names tests ---

    #[test]
    fn test_param_names_from_python_script() {
        let (python_home, _) = match test_python_paths() {
            Some(paths) => paths,
            None => {
                eprintln!("Skipping: python-dist not found");
                return;
            }
        };

        let script = "PARAM_NAMES = {0: \"Cutoff\", 1: \"Resonance\"}\n\ndef process(inputs, outputs, frame_count, sample_rate, params):\n    for ch in range(len(inputs)):\n        outputs[ch][:frame_count] = inputs[ch][:frame_count]\n";
        let temp_dir = std::env::temp_dir();
        let temp_file = temp_dir.join("test_param_names.py");
        std::fs::write(&temp_file, script).unwrap();

        let mut kernel = DSPKernel::new();
        let loaded = kernel.load_script(&python_home, temp_file.to_str().unwrap());
        assert!(loaded);

        let ptr = kernel.param_names_json_ptr();
        assert!(!ptr.is_null());
        let json_str = unsafe { std::ffi::CStr::from_ptr(ptr) }.to_str().unwrap();
        let parsed: std::collections::BTreeMap<String, String> =
            serde_json::from_str(json_str).unwrap();
        assert_eq!(parsed["0"], "Cutoff");
        assert_eq!(parsed["1"], "Resonance");

        std::fs::remove_file(&temp_file).ok();
    }

    #[test]
    fn test_param_names_none_when_not_declared() {
        let (python_home, _) = match test_python_paths() {
            Some(paths) => paths,
            None => {
                eprintln!("Skipping: python-dist not found");
                return;
            }
        };

        let script = "def process(inputs, outputs, frame_count, sample_rate):\n    for ch in range(len(inputs)):\n        outputs[ch][:frame_count] = inputs[ch][:frame_count]\n";
        let temp_dir = std::env::temp_dir();
        let temp_file = temp_dir.join("test_no_param_names.py");
        std::fs::write(&temp_file, script).unwrap();

        let mut kernel = DSPKernel::new();
        let loaded = kernel.load_script(&python_home, temp_file.to_str().unwrap());
        assert!(loaded);

        let ptr = kernel.param_names_json_ptr();
        assert!(ptr.is_null(), "No PARAM_NAMES declared should return null");

        std::fs::remove_file(&temp_file).ok();
    }

    #[test]
    fn test_param_names_cleared_on_new_script() {
        let (python_home, _) = match test_python_paths() {
            Some(paths) => paths,
            None => {
                eprintln!("Skipping: python-dist not found");
                return;
            }
        };

        let temp_dir = std::env::temp_dir();

        // First: script WITH param names
        let script1 = "PARAM_NAMES = {0: \"Rate\"}\n\ndef process(inputs, outputs, frame_count, sample_rate, params):\n    for ch in range(len(inputs)):\n        outputs[ch][:frame_count] = inputs[ch][:frame_count]\n";
        let temp1 = temp_dir.join("test_param_names_1.py");
        std::fs::write(&temp1, script1).unwrap();

        let mut kernel = DSPKernel::new();
        kernel.load_script(&python_home, temp1.to_str().unwrap());
        assert!(!kernel.param_names_json_ptr().is_null());

        // Second: script WITHOUT param names — should clear
        let script2 = "def process(inputs, outputs, frame_count, sample_rate):\n    for ch in range(len(inputs)):\n        outputs[ch][:frame_count] = inputs[ch][:frame_count]\n";
        let temp2 = temp_dir.join("test_param_names_2.py");
        std::fs::write(&temp2, script2).unwrap();

        kernel.load_script(&python_home, temp2.to_str().unwrap());
        assert!(kernel.param_names_json_ptr().is_null(), "Should be cleared after loading script without PARAM_NAMES");

        std::fs::remove_file(&temp1).ok();
        std::fs::remove_file(&temp2).ok();
    }
}
