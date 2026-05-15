use crate::backend::{Backend, SidechainInput, StateSnapshot};
use crate::params::{PARAM_COUNT, TelemetryMetadata};
use crate::python_backend::PythonBackend;
use crate::ring_buffer::AudioRingBuffer;
use crate::wasm_backend::WasmBackend;
use crate::license::SubscriptionStatus;
use arc_swap::ArcSwap;
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicI64, AtomicU32, AtomicU64, AtomicU8, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

/// Default per-script cap for the JSON state buffer (64 KiB). Scripts can
/// raise this via `state!(T, max_bytes = N)` (Rust) — Python presets pin
/// the same default but currently have no opt-in syntax. Audio-thread
/// deserialize cost scales linearly with buffer size, so the default keeps
/// per-block parse time well under 100 µs even on slower hardware.
pub const DEFAULT_STATE_CAP_BYTES: usize = 65_536;

/// Hard upper bound on the per-script cap. Going past 1 MiB risks
/// non-trivial audio-thread parse latency on every state mutation.
pub const MAX_STATE_CAP_BYTES: usize = 1_048_576;

/// Demo limit in seconds. The actual sample count is computed from the host sample rate
/// at `initialize()` time so the demo period is consistent regardless of sample rate.
/// Only buffers with output peak >= DEMO_SILENCE_THRESHOLD count toward this limit,
/// so idle time (no audio playing) does not consume the demo period.
const DEMO_LIMIT_SECONDS: f64 = 60.0;

/// Silence threshold for demo gating: ~-60 dB.
/// Output buffers with peak amplitude below this are considered silent
/// and do not count against the demo time limit.
const DEMO_SILENCE_THRESHOLD: f32 = 0.001;

/// Length of the fade ramp applied when the demo gate opens or closes, in milliseconds.
/// Prevents a click when the demo counter expires (fade to silence) or resets
/// (fade back up to full level on license activation).
const DEMO_FADE_MS: f64 = 5.0;

/// Length of each fade ramp (out and in) applied around a backend swap, in milliseconds.
/// Total silenced window across a swap is ~2 * SWAP_FADE_MS.
/// 15 ms (industry-standard for plugin preset declick) is short enough to feel
/// instantaneous yet long enough to fully absorb step discontinuities between
/// two arbitrary DSP backends with different state, including DC offsets and
/// the difference between large reverb tails and dry signal. Earlier value of
/// 5 ms produced audible clicks on some backend transitions in Logic Pro.
const SWAP_FADE_MS: f64 = 15.0;

/// Maximum wall-clock duration (seconds) the audio thread will hold output
/// muted while waiting for a Swift caller to call `end_preset_transition`.
/// If exceeded the kernel auto-clears `transition_active` so a buggy caller
/// (forgot the matching `end`, crashed mid-transition) can never leave the
/// plugin permanently silent.
const TRANSITION_WATCHDOG_SECONDS: f64 = 2.0;

/// Swap state machine values stored in `DSPKernel::swap_phase` (AtomicU8).
const SWAP_PHASE_IDLE: u8 = 0;
const SWAP_PHASE_FADE_OUT: u8 = 1;
const SWAP_PHASE_FADE_IN: u8 = 2;

/// Host DAW transport state, updated once per render callback via `set_transport()`.
/// All fields default to zero/false, meaning "no transport data available."
/// Written and read on the render thread only — no synchronization needed.
///
/// Field names are the **canonical** ConjureDSP transport names — every
/// language layer (Python `ctx.transport.*`, Rust `setup!()` indices, JS
/// `ConjureDSP.transport.*`) uses the same set so authors don't have to
/// translate between them. `bpm` (not "tempo") matches JUCE precedent and
/// avoids the ambiguity of "tempo" (rate vs. position vs. metronome
/// ticks). `sample_position` is in **samples**, not seconds — convert via
/// `sample_position / sample_rate` if you want seconds.
#[derive(Clone, Copy, Default)]
pub struct TransportState {
    pub bpm: f64,
    pub beat: f64,
    pub is_playing: bool,
    pub time_sig_numerator: i32,
    pub time_sig_denominator: i32,
    pub sample_position: f64,
}

/// Per-vector-telemetry-slot storage indexed by metadata position.
///
/// Each declared vector slot gets a ring of length `max_frames` plus a
/// seqlock counter and a `last_frame_count` so the reader knows how
/// many samples in the ring are valid for the most recent block.
/// Scalar slots have `rings[i] == None`.
///
/// The audio thread is the single writer (try_lock; skip block on
/// contention so we never stall the render callback). UI threads
/// `lock()` briefly on display-link cadence to copy out a snapshot.
/// Allocation/reallocation always runs on the main thread (script
/// load, max-frames change) under the same lock.
struct VecTelemetrySlots {
    /// One entry per metadata slot. `None` for scalar slots, `Some(ring)`
    /// for vector slots. Ring length equals `max_frames`.
    rings: Vec<Option<Vec<AtomicU32>>>,
    /// Per-metadata-slot seqlock counter. Even = stable, odd = writer
    /// in progress. Currently only documentary — the surrounding
    /// `Mutex<VecTelemetrySlots>` already serializes readers vs the
    /// writer, but we publish the counter so a future lock-free reader
    /// path (Phase 2) can switch to true seqlock semantics without
    /// reshaping the storage.
    seqs: Vec<AtomicU32>,
    /// Per-metadata-slot frame count of the most recent write. Reader
    /// uses this to truncate the ring to the live block size.
    last_frame_counts: Vec<AtomicU32>,
    /// Reusable scratch buffer of length `max_frames`, used to bridge
    /// `Backend::read_telemetry_vec` (which writes f32) into the ring's
    /// AtomicU32 storage without per-block allocation.
    scratch: Vec<f32>,
    /// `max_frames` the rings are sized for.
    max_frames: usize,
}

impl VecTelemetrySlots {
    const fn empty() -> Self {
        Self {
            rings: Vec::new(),
            seqs: Vec::new(),
            last_frame_counts: Vec::new(),
            scratch: Vec::new(),
            max_frames: 0,
        }
    }
}

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
    /// Last error from script load or runtime processing.
    /// Written on both the main thread (load failures) and render thread (runtime errors),
    /// so it must be mutex-protected to avoid a data race.
    last_error: Mutex<Option<String>>,
    /// Monotonic counter that bumps on every state change to `last_error`
    /// (None → Some, Some → None, Some(x) → Some(y), and the initial set).
    /// Swift polls this on a 100 ms timer; only when it advances does it
    /// re-read `dsp_kernel_last_error`. Lets the editor surface runtime
    /// errors as Monaco markers without scanning the error string on every
    /// poll. See `update_last_error_blocking` / `_try` for the only legal
    /// write paths.
    error_generation: AtomicU64,
    /// Audio-thread state: was the previous block's process call a failure?
    /// Used to detect the first successful render after an error so the
    /// kernel can clear `last_error` and notify Swift via `error_generation`.
    /// Without this flag the marker would stick until the script reloads.
    had_error_last_block: AtomicBool,
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
    /// Main thread writes (at initialize), audio thread reads — lock-free.
    demo_limit_samples: AtomicU64,
    /// Smoothed demo-gate gain, 0.0..=1.0. Ramps toward 0 when the demo counter
    /// expires and back toward 1 when it's reset, preventing clicks. Written and
    /// read only on the audio thread (inside `process`), so a plain `f32` is fine.
    demo_gain: f32,
    /// Per-sample ramp increment for `demo_gain`, computed from `sample_rate` in
    /// `initialize()` so the fade is a fixed wall-clock duration (DEMO_FADE_MS).
    demo_fade_step: f32,
    /// Cached JSON representation of script-declared parameter names.
    /// Set after each successful script/WASM load. None means "no names declared."
    /// Pointer returned by `param_names_json_ptr()` is valid until next script load or destroy.
    param_names_json: Option<std::ffi::CString>,
    /// Cached JSON representation of rich parameter metadata (name, min, max, unit, default).
    /// Set after each successful script/WASM load that declares a `PARAMS` dict.
    /// None means "no rich metadata" (backward-compatible mode).
    param_metadata_json: Option<std::ffi::CString>,
    /// Per-render-block snapshot of script-published telemetry slots.
    /// f32-as-bits via `to_bits`/`from_bits`, single writer (audio thread,
    /// post-process), readers any thread (Swift display-link tick).
    telemetry: [AtomicU32; crate::params::TELEMETRY_LEN],
    /// Cached JSON metadata for the telemetry slots (name + unit per slot).
    /// Set after each successful script load that declares a `telemetry!()`
    /// block or `TELEMETRY` dict. None means "no telemetry" — Swift skips
    /// the per-tick snapshot read entirely.
    telemetry_metadata_json: Option<std::ffi::CString>,
    /// Typed copy of the telemetry metadata, kept alongside the JSON
    /// cache so the audio thread / vector-ring reallocator can inspect
    /// per-slot `shape` without parsing JSON on every preset swap or
    /// max-frames change.
    telemetry_metadata: Option<Vec<TelemetryMetadata>>,
    /// Per-vector-slot ring buffers + seqlock counters. Sized in
    /// `reallocate_vec_telemetry` whenever metadata or `max_frames`
    /// changes; the audio thread `try_lock`s during `process()` to
    /// publish per-frame values, and UI threads `lock()` briefly on
    /// display-link cadence to read snapshots.
    vec_telemetry: Mutex<VecTelemetrySlots>,
    /// Script-declared algorithmic latency in samples. Zero = no latency.
    /// Read by Swift via FFI to report `AUAudioUnit.latency` for DAW compensation.
    latency_samples: u32,
    /// Host DAW transport state. Updated each render callback via `set_transport()`.
    transport: TransportState,
    /// Real-time profiler: most recent backend.process() duration in microseconds.
    pub(crate) profiler_current_us: AtomicU32,
    /// Real-time profiler: exponential moving average of process duration in microseconds.
    /// Updated each callback as: avg = (5*current + 251*prev) / 256 (~0.5s smoothing).
    pub(crate) profiler_avg_us: AtomicU32,
    /// Real-time profiler: decaying peak duration in microseconds.
    /// Each callback: peak = max(current, peak * 1023/1024).
    pub(crate) profiler_peak_us: AtomicU32,
    /// Current subscription status for UI reporting.
    /// Main thread writes, UI thread reads — lock-free.
    subscription_status: AtomicU8,
    /// Unix timestamp when grace period ends (valid_until + 7 days).
    /// Used by UI to show "X days remaining" warnings.
    grace_deadline_unix: AtomicI64,
    /// Process RSS baseline in bytes, captured when a script is loaded.
    /// Used by MemoryMonitor to detect growth relative to script load time.
    memory_baseline_bytes: AtomicU64,
    /// Current WASM linear memory size in bytes (0 if Python backend).
    /// Updated after each process() call on the audio thread.
    wasm_memory_bytes: AtomicU64,
    /// Actual frame count from the most recent render callback.
    /// May be smaller than max_frames_to_render (e.g. DAW buffers < AU framework minimum).
    /// Written by audio thread, read by UI thread — lock-free.
    last_render_frame_count: AtomicU32,
    /// NAM model paths from the loaded WASM module's `get_nam_manifest_ptr`/`get_nam_manifest_len` exports.
    /// One entry per `nam!()` / `nams!()` slot in declaration order. Set during `load_wasm()`,
    /// read by Swift to resolve and inject each .nam file. Empty when the module declares no NAM models.
    nam_paths: Vec<String>,
    /// Newly loaded backend, staged by the main thread, consumed by the audio thread
    /// at the end of the fade-out half of a preset swap. After the swap completes the
    /// audio thread leaves the *old* backend here so the next main-thread `load_*` call
    /// (or kernel destruction) drops it on a non-real-time thread.
    pending_backend: Mutex<Option<Box<dyn Backend>>>,
    /// Normalized parameter defaults for the staged backend, written by the main thread
    /// alongside `pending_backend` and consumed by the audio thread at the swap point.
    /// Applied atomically with the backend swap so the new backend's first frame already
    /// sees its declared defaults.
    pending_param_defaults: Mutex<Option<[f32; PARAM_COUNT]>>,
    /// Swap state machine: SWAP_PHASE_IDLE / FADE_OUT / FADE_IN.
    /// After the first-load fast path, the audio thread is the sole writer:
    /// the main thread only *requests* a swap by setting `pending_stage_request`
    /// and the audio thread performs the phase transition at the top of its
    /// next callback. This keeps (phase, remaining) updates coherent without
    /// needing a packed atomic or mutex.
    swap_phase: AtomicU8,
    /// Remaining samples in the current fade ramp. Decremented per-sample by the audio
    /// thread; reaching zero triggers a phase transition. Audio-thread-only writer
    /// except during `initialize()` / `install_backend_immediate()` (both cold paths).
    swap_fade_remaining: AtomicU32,
    /// Total length of one fade ramp in samples, recomputed from `sample_rate` in
    /// `initialize()`. Read by the audio thread to derive per-sample envelope step.
    swap_fade_length: AtomicU32,
    /// Signal from main thread to audio thread that a new backend has been staged
    /// and the swap state machine should be (re)armed. The audio thread consumes
    /// this flag at the top of each callback and decides how to transition
    /// `swap_phase` based on its current phase — crucially, a FADE_IN → FADE_OUT
    /// transition preserves gain continuity (rem_out = len − rem_in) so rapid
    /// preset switches mid-fade don't click.
    pending_stage_request: AtomicBool,
    /// `true` while `pending_backend` holds a freshly-staged backend that
    /// hasn't yet been swapped into `live`. Set by `stage_backend_for_swap`
    /// after writing to `pending_backend`; cleared by `perform_swap_locked`
    /// once the swap completes. The audio thread checks this before calling
    /// `perform_swap_locked` so a held preset transition (parked in FADE_OUT
    /// with rem=0 across many callbacks) doesn't oscillate the live ↔ pending
    /// slots — after the first swap, pending holds the *old* backend parked
    /// for deferred drop, and re-swapping would clobber it.
    pending_backend_fresh: AtomicBool,
    /// Reference count of in-flight preset-load transitions. While > 0 the
    /// audio thread holds output muted (FADE_OUT with `swap_fade_remaining == 0`)
    /// and refuses to advance to FADE_IN even after a backend swap completes.
    /// `begin_preset_transition` increments; `end_preset_transition` decrements
    /// (saturating at 0). Audio ramps back up via FADE_IN only when the count
    /// returns to 0 — so two concurrent loads (e.g. user clicks a Rust factory
    /// preset twice in a row, each spawning an async compile Task) only unmute
    /// after BOTH compiles have called their matching `end`. A simple boolean
    /// would race here: the first Task's `end` would clear the flag while the
    /// second Task is still compiling.
    transition_depth: AtomicI32,
    /// Sample-counter of how long `transition_depth` has been > 0. Incremented
    /// per callback by `frame_count` while a transition is active. Reset to 0
    /// on every `begin_preset_transition` so a chain of legitimate overlapping
    /// transitions doesn't trip the watchdog mid-chain. If it crosses
    /// `TRANSITION_WATCHDOG_SECONDS * sample_rate` between `begin` calls (i.e.
    /// no progress for >2 s), the audio thread force-resets `transition_depth`
    /// to 0 to recover from a buggy Swift caller that forgot a matching `end`.
    transition_watchdog_samples: AtomicU32,
    /// Cached state defaults from the most recent script load. Python
    /// presets declare `STATE = {…}` at module level; the Python backend
    /// extracts and serializes it here at load time. WASM presets get
    /// `None` — their defaults are baked into the `T::default()` impl
    /// of the script's State struct and are populated transparently
    /// when the kernel's empty-`{}` buffer is deserialized. Pointer is
    /// valid until the next script load.
    state_defaults_json: Option<std::ffi::CString>,
    /// Bundle-private JSON state buffer. Single canonical source of truth
    /// for per-instance UI-private persisted data (slice marker positions,
    /// step sequencer slot values, anything that isn't a host-automatable
    /// parameter).
    ///
    /// **Memory ordering**: writers store the new buffer (Release-internal
    /// to ArcSwap), then bump `state_generation` with `Ordering::Release`.
    /// Readers load `state_generation` with `Ordering::Acquire` first; only
    /// if it changed do they load the buffer (`Arc::clone`). The
    /// bump-after-swap ordering ensures any reader observing a new
    /// generation also observes the matching buffer.
    state_buffer: ArcSwap<Vec<u8>>,
    /// Monotonically increasing on every accepted state mutation. Backends
    /// cache their parsed state alongside the gen they parsed; equal gen
    /// = re-use cache, different gen = re-deserialize. Acquire/Release
    /// pairs with `state_buffer` updates.
    state_generation: AtomicU64,
    /// Per-script cap on the JSON state buffer. Writes over this size are
    /// rejected by `set_state_json_bytes` (returns false; existing buffer
    /// + generation unchanged). Set at script load via `set_state_cap`;
    /// defaults to `DEFAULT_STATE_CAP_BYTES` for fresh kernels.
    state_cap_bytes: AtomicUsize,
}

/// Get the current process resident memory in bytes via mach task_info.
/// Returns 0 on failure. Safe to call from any thread (~1µs).
pub(crate) fn process_resident_bytes() -> u64 {
    #[cfg(target_os = "macos")]
    {
        // mach_task_basic_info is the modern replacement for task_basic_info.
        // Layout: virtual_size(u64), resident_size(u64), resident_size_max(u64),
        //         user_time(time_value_t=8), system_time(time_value_t=8), policy(i32), suspend_count(i32)
        // Total = 24 + 16 + 8 = 48 bytes = 12 natural_t words
        const MACH_TASK_BASIC_INFO: u32 = 20;
        const MACH_TASK_BASIC_INFO_COUNT: u32 = 12; // 48 bytes / 4 bytes per natural_t

        unsafe extern "C" {
            fn mach_task_self() -> u32;
            fn task_info(
                target_task: u32,
                flavor: u32,
                task_info_out: *mut u8,
                task_info_count: *mut u32,
            ) -> i32;
        }

        #[repr(C)]
        struct MachTaskBasicInfo {
            virtual_size: u64,
            resident_size: u64,
            resident_size_max: u64,
            user_time_seconds: i32,
            user_time_microseconds: i32,
            system_time_seconds: i32,
            system_time_microseconds: i32,
            policy: i32,
            suspend_count: i32,
        }

        let mut info: MachTaskBasicInfo = unsafe { std::mem::zeroed() };
        let mut count = MACH_TASK_BASIC_INFO_COUNT;

        let kr = unsafe {
            task_info(
                mach_task_self(),
                MACH_TASK_BASIC_INFO,
                &mut info as *mut MachTaskBasicInfo as *mut u8,
                &mut count,
            )
        };

        if kr == 0 {
            // KERN_SUCCESS = 0
            info.resident_size
        } else {
            0
        }
    }

    #[cfg(not(target_os = "macos"))]
    0
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
            last_error: Mutex::new(None),
            error_generation: AtomicU64::new(0),
            had_error_last_block: AtomicBool::new(false),
            params: [ZERO; PARAM_COUNT],
            input_ring: AudioRingBuffer::new(AudioRingBuffer::DEFAULT_CAPACITY),
            output_ring: AudioRingBuffer::new(AudioRingBuffer::DEFAULT_CAPACITY),
            capture_enabled: AtomicBool::new(false),
            capture_scratch: vec![0.0; 1024],
            licensed: AtomicBool::new(false),
            demo_samples_processed: AtomicU64::new(0),
            demo_limit_samples: AtomicU64::new((DEMO_LIMIT_SECONDS * 44100.0) as u64),
            // Start fully open so the first callback after plugin load isn't faded in.
            // Gets driven to 0 on demo expiry and back to 1 on reset.
            demo_gain: 1.0,
            demo_fade_step: (1000.0 / (DEMO_FADE_MS * 44100.0)) as f32,
            param_names_json: None,
            param_metadata_json: None,
            telemetry: [ZERO; crate::params::TELEMETRY_LEN],
            telemetry_metadata_json: None,
            telemetry_metadata: None,
            vec_telemetry: Mutex::new(VecTelemetrySlots::empty()),
            latency_samples: 0,
            transport: TransportState::default(),
            profiler_current_us: AtomicU32::new(0),
            profiler_avg_us: AtomicU32::new(0),
            profiler_peak_us: AtomicU32::new(0),
            subscription_status: AtomicU8::new(SubscriptionStatus::NoSubscription as u8),
            grace_deadline_unix: AtomicI64::new(0),
            memory_baseline_bytes: AtomicU64::new(0),
            wasm_memory_bytes: AtomicU64::new(0),
            last_render_frame_count: AtomicU32::new(0),
            nam_paths: Vec::new(),
            pending_backend: Mutex::new(None),
            pending_param_defaults: Mutex::new(None),
            swap_phase: AtomicU8::new(SWAP_PHASE_IDLE),
            swap_fade_remaining: AtomicU32::new(0),
            // Initial value matches the default sample rate (44.1 kHz) so a swap
            // requested before `initialize()` still gets a sensible fade length.
            swap_fade_length: AtomicU32::new((SWAP_FADE_MS / 1000.0 * 44100.0) as u32),
            pending_stage_request: AtomicBool::new(false),
            pending_backend_fresh: AtomicBool::new(false),
            transition_depth: AtomicI32::new(0),
            transition_watchdog_samples: AtomicU32::new(0),
            // Empty JSON object as the initial buffer — signals "no state
            // yet" without needing an Option wrapper. Backends that cache
            // a parsed state at gen=0 against the empty buffer behave
            // identically to "default state" since `serde_json::from_slice`
            // on `{}` populates struct defaults.
            state_buffer: ArcSwap::from_pointee(b"{}".to_vec()),
            state_generation: AtomicU64::new(0),
            state_cap_bytes: AtomicUsize::new(DEFAULT_STATE_CAP_BYTES),
            state_defaults_json: None,
        }
    }

    /// Returns a pointer to the cached state-defaults JSON for the
    /// most recently loaded backend (Python only — WASM presets'
    /// defaults come from the deserializer's struct defaults). Null
    /// when the script declared no STATE dict.
    pub fn state_defaults_json_ptr(&self) -> *const std::os::raw::c_char {
        match &self.state_defaults_json {
            Some(c) => c.as_ptr(),
            None => std::ptr::null(),
        }
    }

    fn update_state_defaults_cache(&mut self, defaults: Option<&str>) {
        self.state_defaults_json = defaults
            .filter(|s| !s.is_empty())
            .and_then(|s| std::ffi::CString::new(s).ok());
    }

    /// Returns the NAM model paths declared by the loaded WASM module, in slot order.
    /// Empty when the module declares no NAM models.
    pub fn nam_paths(&self) -> &[String] {
        &self.nam_paths
    }

    /// Inject NAM model binary data into the loaded WASM backend at the given slot.
    /// Call after `load_wasm()` for each path returned by `nam_paths()`.
    ///
    /// The newly-loaded WASM backend can live in either slot depending on
    /// whether the audio thread has picked up the swap yet:
    /// - If `pending_stage_request` is still set, or the audio thread has
    ///   already moved to `SWAP_PHASE_FADE_OUT`, the new backend is sitting
    ///   in `pending_backend`.
    /// - Otherwise (first-load fast path, or the audio thread already
    ///   completed the swap so the old backend is parked in pending), the
    ///   newest backend lives in the live slot.
    pub fn inject_nam_slot(&mut self, slot: u32, binary_data: &[u8]) -> Result<(), String> {
        // Lock-first ordering closes a TOCTOU race against the audio thread.
        //
        // The newest backend lives in `pending_backend` if either (a) we have
        // staged but the audio thread has not yet consumed the request, or
        // (b) the audio thread is mid-fade-out but has not yet swapped. After
        // the swap completes, `pending_backend` holds the *old* backend parked
        // for deferred drop, and the newest is in `self.backend`.
        //
        // We must not read those state atomics and *then* take the lock — in
        // the gap, the audio thread can finish a fade-out and call
        // `perform_swap_locked`, flipping pending from NEW → OLD. Instead,
        // acquire `pending_backend.lock()` first: while we hold it, the audio
        // thread's `try_lock(pending)` inside `perform_swap_locked` bails out,
        // freezing pending's contents. Only then read the (flag, phase) pair
        // to decide which slot to inject into. The Acquire load on the flag
        // pairs with `apply_pending_stage`'s Release store, so observing
        // `flag=false` guarantees the updated phase is visible.
        let mut pending = self
            .pending_backend
            .lock()
            .map_err(|e| format!("Lock failed: {}", e))?;
        let newest_in_pending = self.pending_stage_request.load(Ordering::Acquire)
            || self.swap_phase.load(Ordering::Acquire) == SWAP_PHASE_FADE_OUT;
        if newest_in_pending {
            if let Some(ref mut backend) = *pending {
                let wasm = backend
                    .as_any_mut()
                    .downcast_mut::<WasmBackend>()
                    .ok_or("Pending backend is not WasmBackend")?;
                return wasm.inject_nam_model_slot(slot, binary_data);
            }
        }
        drop(pending);
        let mut guard = self.backend.lock().map_err(|e| format!("Lock failed: {}", e))?;
        if let Some(ref mut backend) = *guard {
            let wasm = backend.as_any_mut().downcast_mut::<WasmBackend>()
                .ok_or("Backend is not WasmBackend")?;
            wasm.inject_nam_model_slot(slot, binary_data)
        } else {
            Err("No backend loaded".to_string())
        }
    }

    /// Prepend a directory to Python's sys.path so user-installed packages are importable.
    /// Idempotent — safe to call multiple times. Takes effect immediately.
    pub fn set_extra_site_packages(&mut self, path: &str) -> Result<(), String> {
        PythonBackend::inject_site_packages(path)
    }

    /// Mark the start of a preset-load window. The audio thread ramps the output
    /// to silence (5 ms fade-out via the existing swap envelope) and *holds*
    /// silence — even after a backend swap completes — until every matching
    /// `end_preset_transition` has been called. Reference-counted, so two
    /// overlapping loads (e.g. user clicks a Rust factory preset twice in
    /// a row, each spawning an async compile) only unmute after BOTH compiles
    /// finish.
    ///
    /// Wrap every code path that mutates kernel parameters or stages a new
    /// backend (e.g. `selectPreset`, `currentPreset` setter, MCP `save_preset`,
    /// `fullState` restore) so the OLD backend can't be heard rendering audio
    /// with the NEW preset's parameter values during the load window.
    pub fn begin_preset_transition(&self) {
        self.transition_watchdog_samples.store(0, Ordering::Relaxed);
        self.transition_depth.fetch_add(1, Ordering::Release);
    }

    /// Release one nesting level of the mute hold set by
    /// `begin_preset_transition`. The audio thread ramps the output back up
    /// via FADE_IN only when the depth returns to 0 — so the *outer* end
    /// in a chain of overlapping transitions controls when audio resumes.
    /// Saturating at 0 so a stray unpaired call can't drive the depth
    /// negative.
    pub fn end_preset_transition(&self) {
        let _ = self.transition_depth.fetch_update(
            Ordering::Release,
            Ordering::Acquire,
            |d| if d > 0 { Some(d - 1) } else { None },
        );
    }

    /// Returns the current swap-state-machine phase
    /// (IDLE / FADE_OUT / FADE_IN). Diagnostic only — used by tests to
    /// verify that the kernel returned to IDLE after a preset transition.
    pub fn swap_phase(&self) -> u8 {
        self.swap_phase.load(Ordering::Acquire)
    }

    /// Returns whether a preset transition is currently active (depth > 0).
    /// Diagnostic only — used by tests to verify the watchdog has reset
    /// the depth after a buggy caller forgot to call `end_preset_transition`.
    pub fn transition_active(&self) -> bool {
        self.transition_depth.load(Ordering::Acquire) > 0
    }

    pub fn initialize(&mut self, input_channels: i32, _output_channels: i32, sample_rate: f64) {
        // Defensive clamp: the FFI boundary already rejects values outside [8000, 384000],
        // but guard here too so internal callers (tests, benchmark) can never produce NaN/Inf
        // from a division by zero.
        let sr = sample_rate.max(1.0);
        self.sample_rate = sr;
        self.channel_count = input_channels as usize;
        self.demo_limit_samples.store((DEMO_LIMIT_SECONDS * sr) as u64, Ordering::Relaxed);
        // Recompute swap-fade length so the declick envelope is the same wall-clock
        // duration regardless of host sample rate.
        self.swap_fade_length
            .store((SWAP_FADE_MS / 1000.0 * sr) as u32, Ordering::Relaxed);
        // Recompute demo-gate fade step for the new sample rate so the 5ms ramp
        // is consistent across hosts.
        self.demo_fade_step = (1000.0 / (DEMO_FADE_MS * sr)) as f32;
        debug_assert!(
            self.demo_fade_step.is_finite(),
            "demo_fade_step is NaN/Inf: sr={sr}"
        );

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
    ///
    /// On the first load (no live backend yet) the new backend is installed
    /// directly with no fade. On subsequent loads it is staged into
    /// `pending_backend` and the audio thread performs a fade-out → swap →
    /// fade-in declick envelope so users don't hear a pop on preset switch.
    /// Install a bit-exact passthrough backend in response to a failed
    /// script/wasm load. The previous backend is dropped so the user
    /// hears something obviously different (dry signal) instead of the
    /// stale backend continuing to render with the new preset's UI
    /// driving its kernel param slots — which used to feel like the new
    /// preset worked when actually it was the old script being modulated
    /// through new knob ranges.
    ///
    /// Clears every script-derived cache (param metadata, names,
    /// telemetry, state defaults) and resets the state buffer to `{}` so
    /// a subsequent successful load doesn't blend with stale data from
    /// the rejected script. Latency goes back to zero.
    fn install_passthrough_after_failed_load(&mut self) {
        let mut pb = crate::passthrough_backend::PassthroughBackend::new();
        if self.channel_count > 0 {
            pb.initialize(self.channel_count, self.sample_rate, self.max_frames_to_render);
        }
        let boxed: Box<dyn Backend> = Box::new(pb);

        self.update_param_names_cache(std::collections::HashMap::new());
        self.update_param_metadata_cache(None);
        self.update_telemetry_metadata_cache(None);
        self.update_state_defaults_cache(None);
        self.set_state_cap(DEFAULT_STATE_CAP_BYTES);
        let _ = self.set_state_json_bytes(b"{}");
        self.latency_samples = 0;
        self.reset_profiler();
        self.wasm_memory_bytes.store(0, Ordering::Relaxed);
        self.nam_paths = Vec::new();

        // Use the same install path the success branches use. With a
        // live backend present we ride the existing 5 ms declick
        // envelope; on a fresh kernel we install immediately.
        if self.has_live_backend() {
            self.stage_backend_for_swap(boxed, None);
        } else {
            self.install_backend_immediate(boxed, None);
        }
    }

    pub fn load_script(&mut self, python_home: &str, script_path: &str) -> bool {
        match PythonBackend::load(python_home, script_path) {
            Ok(mut pb) => {
                // If already initialized with channels, allocate arrays now
                if self.channel_count > 0 {
                    pb.initialize(self.channel_count, self.sample_rate, self.max_frames_to_render);
                }
                let names = pb.param_names();
                let metadata = pb.param_metadata().map(|m| m.to_vec());
                let telemetry_meta = pb.telemetry_metadata().map(|m| m.to_vec());
                let latency = pb.latency_samples();
                let defaults = Self::defaults_from_metadata(metadata.as_deref());
                // Capture state defaults + cap from the Python backend
                // before we hand it to the staging path (lifetime
                // requires the read happen before the move).
                let state_defaults = pb.state_defaults_json().map(|s| s.to_string());
                let state_cap = pb.state_max_bytes().unwrap_or(DEFAULT_STATE_CAP_BYTES);
                let boxed: Box<dyn Backend> = Box::new(pb);

                // Update caches and reset stats. These are read by Swift via FFI on
                // the main thread (and by the audio thread via atomics for the bare
                // counters), not by the render thread's hot path; safe to publish
                // before the swap actually happens.
                self.update_param_names_cache(names);
                self.update_param_metadata_cache(metadata);
                self.update_telemetry_metadata_cache(telemetry_meta);
                self.update_state_defaults_cache(state_defaults.as_deref());
                self.set_state_cap(state_cap);
                // Reset state buffer to defaults (Python) or empty (WASM).
                // Always-applied — preset switches start from script
                // defaults, not whatever the previous preset's UI wrote.
                let initial_bytes: &[u8] = match state_defaults.as_deref() {
                    Some(s) if !s.is_empty() => s.as_bytes(),
                    _ => b"{}",
                };
                let _ = self.set_state_json_bytes(initial_bytes);
                self.latency_samples = latency;
                self.reset_profiler();
                self.memory_baseline_bytes
                    .store(process_resident_bytes(), Ordering::Relaxed);
                self.wasm_memory_bytes.store(0, Ordering::Relaxed);

                if self.has_live_backend() {
                    self.stage_backend_for_swap(boxed, defaults);
                } else {
                    self.install_backend_immediate(boxed, defaults);
                }

                self.update_last_error_blocking(None);
                // Fresh load wipes any prior runtime-error state on the
                // audio side too; the new backend hasn't failed yet.
                self.had_error_last_block.store(false, Ordering::Relaxed);
                true
            }
            Err(err_msg) => {
                self.install_passthrough_after_failed_load();
                self.update_last_error_blocking(Some(err_msg));
                self.had_error_last_block.store(false, Ordering::Relaxed);
                false
            }
        }
    }

    /// Load a WASM module for DSP processing.
    /// The module must export a `process` function and `memory`.
    /// Returns true on success.
    ///
    /// Uses the same staging + declick path as `load_script`.
    pub fn load_wasm(&mut self, wasm_bytes: &[u8]) -> bool {
        match WasmBackend::load(wasm_bytes) {
            Ok(mut wb) => {
                if self.channel_count > 0 {
                    wb.initialize(self.channel_count, self.sample_rate, self.max_frames_to_render);
                }
                let names = wb.param_names();
                let metadata = wb.param_metadata().map(|m| m.to_vec());
                let telemetry_meta = wb.telemetry_metadata().map(|m| m.to_vec());
                let latency = wb.latency_samples();
                // Store NAM path for Swift to read and inject model data
                self.nam_paths = wb.nam_paths().to_vec();
                let initial_mem = wb.memory_bytes();
                let defaults = Self::defaults_from_metadata(metadata.as_deref());
                let state_cap = wb.state_max_bytes().unwrap_or(DEFAULT_STATE_CAP_BYTES);
                let boxed: Box<dyn Backend> = Box::new(wb);

                self.update_param_names_cache(names);
                self.update_param_metadata_cache(metadata);
                self.update_telemetry_metadata_cache(telemetry_meta);
                // WASM scripts have no module-level STATE dict — their
                // defaults come from the script's `Default` impl when
                // `serde_json::from_slice` is called on the empty `{}`
                // buffer. So we clear any cached defaults from a prior
                // load and reset the kernel buffer to `{}`.
                self.update_state_defaults_cache(None);
                self.set_state_cap(state_cap);
                let _ = self.set_state_json_bytes(b"{}");
                self.latency_samples = latency;
                self.reset_profiler();
                self.memory_baseline_bytes
                    .store(process_resident_bytes(), Ordering::Relaxed);
                self.wasm_memory_bytes.store(initial_mem, Ordering::Relaxed);

                if self.has_live_backend() {
                    self.stage_backend_for_swap(boxed, defaults);
                } else {
                    self.install_backend_immediate(boxed, defaults);
                }

                self.update_last_error_blocking(None);
                self.had_error_last_block.store(false, Ordering::Relaxed);
                true
            }
            Err(err_msg) => {
                self.install_passthrough_after_failed_load();
                self.update_last_error_blocking(Some(err_msg));
                self.had_error_last_block.store(false, Ordering::Relaxed);
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

    /// Update host DAW transport state. Called from the render thread
    /// once per callback, before the process loop.
    pub fn set_transport(
        &mut self,
        bpm: f64,
        beat: f64,
        is_playing: bool,
        time_sig_numerator: i32,
        time_sig_denominator: i32,
        sample_position: f64,
    ) {
        self.transport = TransportState {
            bpm,
            beat,
            is_playing,
            time_sig_numerator,
            time_sig_denominator,
            sample_position,
        };
    }

    // ─── State channel ──────────────────────────────────────────────

    /// Set the per-script size cap on the state buffer. Called by Swift
    /// at script load. Subsequent `set_state_json_bytes` calls reject
    /// inputs over this size. Clamped to `MAX_STATE_CAP_BYTES`.
    pub fn set_state_cap(&self, max_bytes: usize) {
        let clamped = max_bytes.min(MAX_STATE_CAP_BYTES);
        self.state_cap_bytes.store(clamped, Ordering::Relaxed);
    }

    /// Return the per-script size cap on the state buffer.
    pub fn state_cap(&self) -> usize {
        self.state_cap_bytes.load(Ordering::Relaxed)
    }

    /// Try to install a new state buffer.
    ///
    /// Validates that `bytes` is well-formed JSON and is no larger than
    /// the per-script cap. On success, atomically swaps the buffer and
    /// bumps the generation counter (Release-ordered) so audio-thread
    /// readers re-parse on their next callback. On failure the existing
    /// buffer + generation are unchanged.
    ///
    /// Returns `true` on success, `false` on any rejection (over cap or
    /// invalid JSON).
    pub fn set_state_json_bytes(&self, bytes: &[u8]) -> bool {
        let cap = self.state_cap_bytes.load(Ordering::Relaxed);
        if bytes.len() > cap {
            return false;
        }
        // Cheap structural validation — a malformed payload from JS / MCP
        // would otherwise blow up backend deserialize on every render
        // until the next set. `from_slice` on a 64 KiB buffer is well
        // under a millisecond.
        if serde_json::from_slice::<serde_json::Value>(bytes).is_err() {
            return false;
        }
        let new_buf = Arc::new(bytes.to_vec());
        // Order matters: store buffer first, then bump gen. Readers loading
        // gen with Acquire that observe the new value are guaranteed to
        // also observe the new buffer (paired with ArcSwap::store, which
        // has Release semantics on the pointer write).
        self.state_buffer.store(new_buf);
        self.state_generation.fetch_add(1, Ordering::Release);
        true
    }

    /// Snapshot the current state buffer for the audio thread.
    ///
    /// Returns `(generation, buffer_arc)`. Backends compare the gen
    /// against their cached gen; on mismatch they re-deserialize and
    /// update the cache. Cheap in the steady state — one Acquire load +
    /// one Arc::clone on miss.
    pub fn snapshot_state(&self) -> (u64, Arc<Vec<u8>>) {
        let generation = self.state_generation.load(Ordering::Acquire);
        let buf = self.state_buffer.load_full();
        (generation, buf)
    }

    /// Read the current generation counter without taking the buffer.
    /// Used by the smoke tester to verify a write actually landed.
    pub fn state_generation(&self) -> u64 {
        self.state_generation.load(Ordering::Acquire)
    }

    /// Read the current state buffer as a fresh `Vec<u8>` copy. Used by
    /// the AU's `fullState` / `fullStateForDocument` getters which need
    /// owned bytes for the dictionary.
    pub fn state_json_bytes_copy(&self) -> Vec<u8> {
        let buf = self.state_buffer.load_full();
        (*buf).clone()
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

    /// Update profiler statistics after a backend.process() call.
    /// Called from the audio thread — uses only atomics and integer math.
    fn update_profiler(&self, elapsed_us: u32) {
        self.profiler_current_us.store(elapsed_us, Ordering::Relaxed);
        // EMA: new = (5*current + 251*prev) / 256 (~0.5s smoothing)
        // Seed with current value when starting from zero to avoid integer
        // truncation keeping avg stuck at 0 (e.g. (5*1 + 251*0)/256 = 0).
        let prev_avg = self.profiler_avg_us.load(Ordering::Relaxed);
        let new_avg = if prev_avg == 0 {
            elapsed_us
        } else {
            ((5u64 * elapsed_us as u64 + 251u64 * prev_avg as u64) / 256) as u32
        };
        self.profiler_avg_us.store(new_avg, Ordering::Relaxed);
        // Decaying peak: peak * 1023/1024, then max with current
        let prev_peak = self.profiler_peak_us.load(Ordering::Relaxed);
        let decayed = ((prev_peak as u64 * 1023) / 1024) as u32;
        self.profiler_peak_us.store(elapsed_us.max(decayed), Ordering::Relaxed);
    }

    /// Get the process RSS baseline recorded when the current script was loaded.
    pub fn memory_baseline_bytes(&self) -> u64 {
        self.memory_baseline_bytes.load(Ordering::Relaxed)
    }

    /// Get the current WASM linear memory size in bytes (0 if Python backend).
    pub fn wasm_memory_bytes(&self) -> u64 {
        self.wasm_memory_bytes.load(Ordering::Relaxed)
    }

    /// Get the actual frame count from the most recent render callback.
    /// Returns 0 before the first render call.
    pub fn last_render_frame_count(&self) -> u32 {
        self.last_render_frame_count.load(Ordering::Relaxed)
    }

    /// Reset profiler statistics. Called when a new script/WASM is loaded.
    fn reset_profiler(&self) {
        self.profiler_current_us.store(0, Ordering::Relaxed);
        self.profiler_avg_us.store(0, Ordering::Relaxed);
        self.profiler_peak_us.store(0, Ordering::Relaxed);
    }

    pub fn maximum_frames_to_render(&self) -> u32 {
        self.max_frames_to_render
    }

    pub fn set_maximum_frames_to_render(&mut self, max_frames: u32) {
        self.max_frames_to_render = max_frames;
        // Resize scratch buffer to match (no allocation on audio thread)
        self.capture_scratch.resize(max_frames as usize, 0.0);
        // Vector-telemetry rings are sized to max_frames; resize them too
        // so subsequent harvests have room for full per-frame writes.
        self.reallocate_vec_telemetry();
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
        let remaining = self.demo_limit_samples.load(Ordering::Relaxed).saturating_sub(processed);
        // Guard against a zero/NaN sample_rate so we never return NaN/Inf to Swift.
        let sr = if sample_rate > 0.0 && sample_rate.is_finite() {
            sample_rate
        } else {
            self.sample_rate.max(1.0)
        };
        remaining as f64 / sr
    }

    /// Reset the demo sample counter to zero, giving another 60 seconds of demo time.
    pub fn reset_demo(&self) {
        self.demo_samples_processed.store(0, Ordering::Relaxed);
    }

    /// Set the subscription status and update the licensed flag accordingly.
    /// Active and GracePeriod grant licensed access; everything else → demo mode.
    pub fn set_subscription_status(&self, status: SubscriptionStatus) {
        self.subscription_status.store(status as u8, Ordering::Relaxed);
        self.licensed.store(status.is_licensed(), Ordering::Relaxed);
        if status.is_licensed() {
            self.demo_samples_processed.store(0, Ordering::Relaxed);
        }
    }

    /// Read the current subscription status.
    pub fn subscription_status(&self) -> SubscriptionStatus {
        SubscriptionStatus::from_u8(self.subscription_status.load(Ordering::Relaxed))
    }

    /// Set the grace period deadline (Unix seconds) for UI display.
    pub fn set_grace_deadline_unix(&self, deadline: i64) {
        self.grace_deadline_unix.store(deadline, Ordering::Relaxed);
    }

    /// Read the grace period deadline (Unix seconds).
    pub fn grace_deadline_unix(&self) -> i64 {
        self.grace_deadline_unix.load(Ordering::Relaxed)
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

        if channel_count == 0 {
            return;
        } else if channel_count == 1 {
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

    /// Returns the last error message, if any. Safe to call from any thread.
    pub fn last_error(&self) -> Option<String> {
        self.last_error.lock().ok()?.clone()
    }

    /// Sets the last error message. Safe to call from any thread.
    /// Bumps `error_generation` on an actual state change so Swift's poll
    /// notices the new value.
    pub(crate) fn set_last_error(&self, err: Option<String>) {
        self.update_last_error_blocking(err);
    }

    /// Returns the current `error_generation` counter. Swift polls this to
    /// detect transitions; reads `dsp_kernel_last_error` only when the
    /// value advances.
    pub fn error_generation(&self) -> u64 {
        self.error_generation.load(Ordering::Acquire)
    }

    /// Writes `err` to `last_error` and bumps `error_generation` if the
    /// value actually changed. Blocks on the mutex — only safe to call
    /// from the main thread (e.g. load paths).
    ///
    /// Returns true if the new value was written, false if the value was
    /// already equal or the mutex was poisoned.
    fn update_last_error_blocking(&self, err: Option<String>) -> bool {
        if let Ok(mut guard) = self.last_error.lock() {
            if *guard != err {
                *guard = err;
                self.error_generation.fetch_add(1, Ordering::Release);
                return true;
            }
        }
        false
    }

    /// Audio-thread variant of `update_last_error_blocking`: uses
    /// `try_lock` instead of `lock` to avoid blocking the render thread
    /// when the main thread briefly holds the mutex. Drops the write on
    /// contention; the next failing block will set it again, and the
    /// success path is contention-free in steady state.
    ///
    /// Returns `true` when the lock was acquired (whether or not the
    /// value changed — the no-op case still reflects committed state),
    /// `false` on contention. Callers use this to gate audio-thread
    /// state that depends on the kernel error having reached the value
    /// they wrote (e.g. clearing `had_error_last_block` in the recovery
    /// branch only when the paired `last_error = None` actually landed).
    fn update_last_error_try(&self, err: Option<String>) -> bool {
        if let Ok(mut guard) = self.last_error.try_lock() {
            if *guard != err {
                *guard = err;
                self.error_generation.fetch_add(1, Ordering::Release);
            }
            true
        } else {
            false
        }
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
    ///
    /// Note: this used to also write the metadata defaults into the param atomics.
    /// That happened on the main thread immediately after a backend swap, which
    /// caused parameter values to jump abruptly mid-render and contributed to the
    /// audible pop on preset switch. Defaults are now staged into
    /// `pending_param_defaults` and applied atomically with the swap on the audio
    /// thread (see `stage_backend_for_swap`), so the new backend's first frame
    /// already sees its declared defaults and old-backend frames keep their old
    /// values until the fade-out completes.
    fn update_param_metadata_cache(&mut self, metadata: Option<Vec<crate::params::ParamMetadata>>) {
        match metadata {
            Some(meta) if !meta.is_empty() => {
                self.param_metadata_json = serde_json::to_string(&meta)
                    .ok()
                    .and_then(|s| std::ffi::CString::new(s).ok());
            }
            _ => {
                self.param_metadata_json = None;
            }
        }
    }

    /// Update the cached JSON for telemetry slot metadata. Set to None
    /// when the script declares no telemetry, so Swift can short-circuit
    /// the per-tick `read_telemetry` snapshot read.
    pub(crate) fn update_telemetry_metadata_cache(
        &mut self,
        metadata: Option<Vec<crate::params::TelemetryMetadata>>,
    ) {
        match metadata {
            Some(meta) if !meta.is_empty() => {
                self.telemetry_metadata_json = serde_json::to_string(&meta)
                    .ok()
                    .and_then(|s| std::ffi::CString::new(s).ok());
                self.telemetry_metadata = Some(meta);
            }
            _ => {
                self.telemetry_metadata_json = None;
                self.telemetry_metadata = None;
            }
        }
        // Clear the snapshot too — stale values from the previous
        // script's slots would otherwise leak into the first reads
        // after a swap.
        for slot in &self.telemetry {
            slot.store(0, Ordering::Relaxed);
        }
        // Resize per-vector-slot rings to match the new metadata. Runs
        // on the main thread under `&mut self`, so allocation is fine.
        self.reallocate_vec_telemetry();
    }

    /// (Re)allocate the per-vector-slot rings + scratch to match the
    /// current `telemetry_metadata` and `max_frames_to_render`.
    ///
    /// Called whenever either input changes (new script loaded, host
    /// max-frames updated). Always runs on the main thread under
    /// `&mut self`; the audio thread is guaranteed not to be inside
    /// `process()` at the same instant by Rust's exclusive-borrow
    /// rules + Swift's FFI sequencing. We still take the inner
    /// mutex so a UI display-link reader holding it sees a coherent
    /// pre/post-state rather than a half-resized vector.
    fn reallocate_vec_telemetry(&mut self) {
        let max_frames = self.max_frames_to_render as usize;
        let slot_count = self
            .telemetry_metadata
            .as_ref()
            .map(|m| m.len())
            .unwrap_or(0);

        // Build the new contents off-mutex so the lock is held only
        // for the swap-in. Allocation cost is paid on the main thread.
        let mut rings: Vec<Option<Vec<AtomicU32>>> = Vec::with_capacity(slot_count);
        let mut seqs: Vec<AtomicU32> = Vec::with_capacity(slot_count);
        let mut last_frame_counts: Vec<AtomicU32> = Vec::with_capacity(slot_count);
        if let Some(meta) = &self.telemetry_metadata {
            for spec in meta {
                if spec.is_vector() && max_frames > 0 {
                    let mut ring: Vec<AtomicU32> = Vec::with_capacity(max_frames);
                    for _ in 0..max_frames {
                        ring.push(AtomicU32::new(0));
                    }
                    rings.push(Some(ring));
                } else {
                    rings.push(None);
                }
                seqs.push(AtomicU32::new(0));
                last_frame_counts.push(AtomicU32::new(0));
            }
        }
        let scratch = vec![0.0_f32; max_frames];

        if let Ok(mut guard) = self.vec_telemetry.lock() {
            *guard = VecTelemetrySlots {
                rings,
                seqs,
                last_frame_counts,
                scratch,
                max_frames,
            };
        }
    }

    /// Compute normalized parameter defaults from rich metadata.
    /// Returns `None` for backends with no metadata (legacy 0–1 mode); in that case
    /// the existing param values are preserved across the swap.
    fn defaults_from_metadata(
        metadata: Option<&[crate::params::ParamMetadata]>,
    ) -> Option<[f32; PARAM_COUNT]> {
        let meta = metadata?;
        if meta.is_empty() {
            return None;
        }
        let mut out = [0.0f32; PARAM_COUNT];
        for (i, m) in meta.iter().enumerate().take(PARAM_COUNT) {
            out[i] = m.normalize(m.default);
        }
        Some(out)
    }

    /// Stage a freshly loaded backend for installation by the audio thread.
    ///
    /// Drains any previously staged backend (dropped on this main thread, never on
    /// the audio thread), writes the new backend and its parameter defaults into
    /// the staging slots, and raises `pending_stage_request` so the audio thread
    /// will arm the swap state machine at the top of its next callback.
    ///
    /// Phase transitions are deliberately delegated to the audio thread — it is
    /// the sole writer of `swap_phase`/`swap_fade_remaining` during the hot path,
    /// so updating them from here would require a coherent multi-field atomic
    /// update. Letting the audio thread own the transition also makes the
    /// gain-preserving FADE_IN → FADE_OUT path trivial (see `apply_pending_stage`).
    fn stage_backend_for_swap(
        &mut self,
        new_backend: Box<dyn Backend>,
        defaults: Option<[f32; PARAM_COUNT]>,
    ) {
        // Drain any previously staged backend so it's dropped here, not on audio.
        // This handles two cases:
        //   1. Audio thread has already completed a previous swap and parked the
        //      old backend in pending_backend for us to drop.
        //   2. The user clicked another preset before the audio thread even
        //      reached the previous swap point — drop the unconsumed previous
        //      pending backend so it doesn't leak.
        //
        // The backend and its parameter defaults must be published atomically
        // from the audio thread's perspective: if we released
        // `pending_backend.lock()` between writing the backend and writing the
        // defaults, `perform_swap_locked` could run in the gap, swap in the
        // new backend, then find `pending_param_defaults` locked by us and
        // skip applying the defaults — leaving the new backend running with
        // stale parameter values from the previous preset. To prevent this
        // we hold `pending_backend.lock()` across both writes. The audio
        // thread takes the same lock order (pending_backend → pending_param_defaults
        // inside `perform_swap_locked`), so there is no deadlock risk.
        if let Ok(mut pending) = self.pending_backend.lock() {
            *pending = Some(new_backend);
            if let Ok(mut staged_defaults) = self.pending_param_defaults.lock() {
                *staged_defaults = defaults;
            }
        }
        // Mark pending as fresh BEFORE raising pending_stage_request. The audio
        // thread's Acquire load on pending_stage_request synchronizes with both
        // writes; combined with the perform_swap_locked code path, this means
        // the audio thread will only swap when there's actually a new backend
        // to install — never re-swap the parked old backend during a held
        // transition.
        self.pending_backend_fresh
            .store(true, Ordering::Release);
        // Raise the request flag after the backend + defaults are published so
        // the Acquire load on the audio side synchronizes with those writes.
        self.pending_stage_request
            .store(true, Ordering::Release);
    }

    /// Audio-thread handler for a pending stage request. Transitions the swap
    /// state machine based on the current phase:
    ///
    /// - `IDLE`: start a fresh fade-out from full volume (new len samples).
    /// - `FADE_OUT`: already fading out — leave `swap_fade_remaining` alone so
    ///   the in-progress fade completes naturally before picking up the newly
    ///   staged backend.
    /// - `FADE_IN`: preserve gain continuity. During fade-in the current
    ///   envelope gain is `1 − rem_in/len`; to continue smoothly into a
    ///   fade-out at that same gain we need `rem_out/len` to equal the same
    ///   value, i.e. `rem_out = len − rem_in`. This avoids the click that
    ///   would otherwise occur when the user rapidly switches presets during
    ///   the fade-in half of a previous swap.
    ///
    /// **Ordering invariant**: the phase/remaining updates must happen *before*
    /// clearing `pending_stage_request`, with a Release store on the clear.
    /// Main-thread readers (`inject_nam_slot`, `benchmark_process`) use this to
    /// decide whether the newest backend lives in `pending_backend` or the
    /// live slot: reading `flag=false` via Acquire guarantees the updated
    /// phase is visible, so a `(flag=false, phase=FADE_OUT)` snapshot reliably
    /// means "audio consumed the stage, pending still holds the new backend,
    /// swap has not yet completed". If we cleared the flag before the phase
    /// store, a reader could see `(flag=false, phase=IDLE-stale)` and wrongly
    /// route to the live slot, injecting into the old backend.
    fn apply_pending_stage(&self) {
        if !self.pending_stage_request.load(Ordering::Acquire) {
            return;
        }
        let len = self.swap_fade_length.load(Ordering::Relaxed);
        let phase = self.swap_phase.load(Ordering::Relaxed);
        match phase {
            SWAP_PHASE_IDLE => {
                self.swap_fade_remaining.store(len, Ordering::Relaxed);
                self.swap_phase
                    .store(SWAP_PHASE_FADE_OUT, Ordering::Release);
            }
            SWAP_PHASE_FADE_IN => {
                let rem_in = self.swap_fade_remaining.load(Ordering::Relaxed);
                self.swap_fade_remaining
                    .store(len.saturating_sub(rem_in), Ordering::Relaxed);
                self.swap_phase
                    .store(SWAP_PHASE_FADE_OUT, Ordering::Release);
            }
            SWAP_PHASE_FADE_OUT => {
                // Already fading out — finish this fade, then pick up the new
                // backend at the swap point. `swap_fade_remaining` left alone.
            }
            _ => {}
        }
        // Clear the flag LAST, with Release ordering, so any reader observing
        // flag=false via Acquire is guaranteed to also see the updated phase.
        self.pending_stage_request
            .store(false, Ordering::Release);
    }

    /// Audio-thread handler for the `transition_active` flag set by
    /// `begin_preset_transition`. Drives the swap state machine into
    /// FADE_OUT (from IDLE or, mid fade-in, with gain continuity) so the
    /// output is ramped to silence and *held* there. The actual hold is
    /// enforced at the FADE_OUT-completion site in `process()`, which
    /// refuses to advance to FADE_IN while `transition_active` is true.
    ///
    /// Also runs the watchdog: if the flag has been set for longer than
    /// `TRANSITION_WATCHDOG_SECONDS` of audio, force-clear it so a buggy
    /// Swift caller (forgot the matching `end`, crashed mid-transition)
    /// can never leave the plugin permanently silent.
    fn apply_transition_state(&self, frames_processed: u32) {
        if self.transition_depth.load(Ordering::Acquire) <= 0 {
            return;
        }
        // Watchdog. fetch_add returns the PRE-update value; add `frames_processed`
        // back to compare elapsed against the limit.
        let prev = self.transition_watchdog_samples
            .fetch_add(frames_processed, Ordering::Relaxed);
        let elapsed = prev.saturating_add(frames_processed);
        let limit = (TRANSITION_WATCHDOG_SECONDS * self.sample_rate) as u32;
        if elapsed >= limit {
            self.transition_depth.store(0, Ordering::Release);
            // Best-effort error report for Swift / logs. try_lock so we never
            // stall the audio thread on a contended mutex.
            if let Ok(mut last) = self.last_error.try_lock() {
                let secs = elapsed as f64 / self.sample_rate.max(1.0);
                *last = Some(format!(
                    "preset transition watchdog fired after {:.2}s — recovering",
                    secs
                ));
            }
            return;
        }
        // Drive the state machine to FADE_OUT so output ramps to silence.
        // Mirrors `apply_pending_stage`'s phase logic — including the
        // FADE_IN → FADE_OUT gain-continuity path so a transition that
        // begins mid fade-in doesn't click.
        let phase = self.swap_phase.load(Ordering::Relaxed);
        let len = self.swap_fade_length.load(Ordering::Relaxed);
        match phase {
            SWAP_PHASE_IDLE => {
                self.swap_fade_remaining.store(len, Ordering::Relaxed);
                self.swap_phase.store(SWAP_PHASE_FADE_OUT, Ordering::Release);
            }
            SWAP_PHASE_FADE_IN => {
                let rem_in = self.swap_fade_remaining.load(Ordering::Relaxed);
                self.swap_fade_remaining
                    .store(len.saturating_sub(rem_in), Ordering::Relaxed);
                self.swap_phase.store(SWAP_PHASE_FADE_OUT, Ordering::Release);
            }
            // Already in FADE_OUT — let the existing fade complete; the
            // hold-at-zero behavior takes over at the FADE_OUT-completion
            // site in process().
            _ => {}
        }
    }

    /// Install a backend directly into the live slot, bypassing the staging path.
    /// Used for the very first load on a fresh kernel where there is no live backend
    /// to fade out from. Falls back to the staging path if a live backend already
    /// exists, so callers can use this unconditionally.
    fn install_backend_immediate(
        &mut self,
        new_backend: Box<dyn Backend>,
        defaults: Option<[f32; PARAM_COUNT]>,
    ) {
        // Apply defaults first (no audio thread is using these atomics yet).
        if let Some(d) = defaults {
            for (i, &val) in d.iter().enumerate().take(PARAM_COUNT) {
                self.params[i].store(val.to_bits(), Ordering::Relaxed);
            }
        }
        if let Ok(mut guard) = self.backend.lock() {
            *guard = Some(new_backend);
        }
        // Make sure we're not stuck in a fade phase from a previous swap.
        self.swap_phase.store(SWAP_PHASE_IDLE, Ordering::Release);
        self.swap_fade_remaining.store(0, Ordering::Relaxed);
        // Cold path didn't go through stage; nothing fresh in pending.
        self.pending_backend_fresh.store(false, Ordering::Release);
    }

    /// True if the live backend slot is empty (no backend has been installed yet).
    fn has_live_backend(&self) -> bool {
        self.backend
            .lock()
            .map(|g| g.is_some())
            .unwrap_or(false)
    }

    /// Returns a pointer to the cached parameter metadata JSON, or null if none declared.
    /// The pointer is valid until the next script load or kernel destroy.
    pub fn param_metadata_json_ptr(&self) -> *const std::os::raw::c_char {
        match &self.param_metadata_json {
            Some(cstr) => cstr.as_ptr(),
            None => std::ptr::null(),
        }
    }

    /// Returns a pointer to the cached telemetry slot metadata JSON
    /// (`[{name, key?, unit}, …]`), or null when the script declared no
    /// telemetry. Pointer is valid until the next script load or kernel
    /// destroy.
    pub fn telemetry_metadata_json_ptr(&self) -> *const std::os::raw::c_char {
        match &self.telemetry_metadata_json {
            Some(cstr) => cstr.as_ptr(),
            None => std::ptr::null(),
        }
    }

    /// Snapshot the latest telemetry values into the caller's buffer.
    /// Writes up to `out.len()` slots (capped at `TELEMETRY_LEN`) and
    /// returns the number of slots written. Lock-free Relaxed read of
    /// the per-slot atomics — single writer (audio thread, post-process)
    /// vs. arbitrary readers (Swift display-link).
    pub fn read_telemetry(&self, out: &mut [f32]) -> usize {
        let n = out.len().min(self.telemetry.len());
        for i in 0..n {
            out[i] = f32::from_bits(self.telemetry[i].load(Ordering::Relaxed));
        }
        n
    }

    /// Snapshot the latest per-frame values written by the most recent
    /// `process()` call for the vector telemetry slot at metadata
    /// position `slot`. Returns the number of samples actually written
    /// to `out` (may be less than `out.len()` when the host's last
    /// block had fewer frames than the buffer, or zero when the slot
    /// is scalar / not declared / has not been written yet).
    ///
    /// Single-reader-friendly: takes `&self` and locks the inner mutex
    /// briefly. The audio thread always uses `try_lock`, so a contended
    /// UI read can stall the writer for at most one display-link tick
    /// in pathological cases — fine in practice at 30–120 Hz read rates.
    pub fn read_telemetry_vec(&self, slot: usize, out: &mut [f32]) -> usize {
        let guard = match self.vec_telemetry.lock() {
            Ok(g) => g,
            Err(_) => return 0,
        };
        if slot >= guard.rings.len() {
            return 0;
        }
        let ring = match &guard.rings[slot] {
            Some(r) => r,
            None => return 0,
        };
        let live = guard.last_frame_counts[slot].load(Ordering::Acquire) as usize;
        let n = live.min(out.len()).min(ring.len());
        for i in 0..n {
            out[i] = f32::from_bits(ring[i].load(Ordering::Relaxed));
        }
        n
    }

    /// Returns script-declared algorithmic latency in samples (0 = no latency).
    pub fn latency_samples(&self) -> u32 {
        self.latency_samples
    }

    /// Capture any backend error into `last_error` so it outlives the mutex guard.
    /// Uses `try_lock` so it's safe to call from any thread (including the
    /// audio thread); drops the capture on contention.
    fn capture_backend_error(&self) {
        if let Ok(backend_guard) = self.backend.try_lock() {
            if let Some(ref backend) = *backend_guard {
                if let Some(err) = backend.last_error() {
                    self.update_last_error_try(Some(err.to_string()));
                }
            }
        }
    }

    /// Benchmark the process function with a 440 Hz sine wave.
    /// Returns the max execution time in seconds over 5 runs (after 1 warm-up),
    /// or None if no backend is loaded or the swap doesn't complete in time.
    ///
    /// Waits (up to 100 ms) for any in-flight preset swap to complete, then
    /// benchmarks the live slot. We intentionally do NOT benchmark while the
    /// new backend is still parked in `pending_backend`: holding
    /// `pending_backend.lock()` for the full ~50-100 ms benchmark duration
    /// would block the audio thread's `perform_swap_locked` from completing
    /// its non-blocking `try_lock`, stranding the envelope in `FADE_OUT` with
    /// `remaining=0` and producing an extended silence dropout. Waiting for
    /// `phase == IDLE` costs at most ~10 ms (the full fade envelope) in
    /// exchange for benchmarking the freshly-loaded preset from the live slot
    /// exactly like a first-load backend.
    pub fn benchmark_process(&mut self) -> Option<f64> {
        let channel_count = if self.channel_count > 0 {
            self.channel_count
        } else {
            2
        };
        let frame_count = self.max_frames_to_render as usize;
        let sample_rate = if self.sample_rate > 0.0 {
            self.sample_rate
        } else {
            44100.0
        };

        // Generate 440 Hz sine wave input
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

        let needs_temp_init = self.channel_count == 0;
        let params = self.snapshot_params();
        let transport = self.transport;
        let max_frames = self.max_frames_to_render;

        // Helper that runs the actual benchmark on a given backend.
        // Defined as a closure to avoid the borrow-checker tangle from calling
        // a `&mut self` method while holding a MutexGuard from a `&self` field.
        let run = |backend: &mut dyn Backend| -> f64 {
            if needs_temp_init {
                backend.initialize(channel_count, sample_rate, max_frames);
            }
            // Warm-up
            unsafe {
                backend.process(
                    &input_ptrs,
                    &output_ptrs,
                    channel_count,
                    frame_count,
                    sample_rate,
                    &params,
                    &transport,
                    SidechainInput::NONE,
                    &StateSnapshot::empty(),
                );
            }
            let mut max_time = 0.0f64;
            for _ in 0..5 {
                let start = std::time::Instant::now();
                unsafe {
                    backend.process(
                        &input_ptrs,
                        &output_ptrs,
                        channel_count,
                        frame_count,
                        sample_rate,
                        &params,
                        &transport,
                        SidechainInput::NONE,
                        &StateSnapshot::empty(),
                    );
                }
                let elapsed = start.elapsed().as_secs_f64();
                if elapsed > max_time {
                    max_time = elapsed;
                }
            }
            if needs_temp_init {
                backend.deinitialize();
            }
            max_time
        };

        // Wait for the staged swap to actually land in the live slot before
        // benchmarking. While a swap is pending or in flight, the newest
        // backend lives in `pending_backend`; benchmarking it there would
        // require holding `pending_backend.lock()` for ~50-100 ms — long
        // enough to block the audio thread's `perform_swap_locked` from ever
        // progressing, which strands the envelope at zero gain.
        //
        // Poll `pending_backend_fresh` (cleared by the audio thread after
        // `perform_swap_locked` succeeds) rather than `swap_phase == IDLE`.
        // During a held preset transition (Swift wrapped this load in
        // `begin_preset_transition` / `end_preset_transition`) the audio
        // thread parks in `FADE_OUT` indefinitely after the swap, so polling
        // for IDLE would always time out — but `pending_backend_fresh` clears
        // as soon as the swap actually completes, regardless of whether the
        // envelope advances to FADE_IN or stays parked.
        let deadline = std::time::Instant::now() + std::time::Duration::from_millis(100);
        while self.pending_stage_request.load(Ordering::Acquire)
            || self.pending_backend_fresh.load(Ordering::Acquire)
        {
            if std::time::Instant::now() >= deadline {
                // Swap is wedged or taking longer than expected — bail out
                // rather than benchmark a backend that might still be stale.
                return None;
            }
            std::thread::sleep(std::time::Duration::from_millis(1));
        }

        // After phase == IDLE the newest backend is guaranteed to be in the
        // live slot (either via the first-load fast path or because the
        // audio thread already swapped and the fade-in has completed). We
        // can lock `self.backend` directly and leave `pending_backend`
        // untouched so the audio thread's swap machinery is never blocked.
        let mut live = self.backend.lock().ok()?;
        let result = live.as_mut().map(|b| run(b.as_mut()));
        drop(live);

        // If the benchmark traps every block (e.g. a script that panics on
        // first sample), `run` returns a wall-clock time but the trap is
        // captured only in `backend.last_error`. Drain it into the kernel's
        // `last_error` so `dsp_kernel_last_error` and the MCP surface can
        // report "compiles but crashes on first block" without waiting for
        // a live render to retrigger the trap.
        self.capture_backend_error();

        // Reset profiler — benchmark would have contaminated it if we'd routed
        // through self.process(). We don't go through process() any more, but
        // keep the reset for parity with previous behavior.
        self.reset_profiler();

        result
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
        // Legacy entry point — no sidechain. New callers should prefer
        // `process_with_sidechain`. Routes through the same code path with
        // a sentinel "disconnected" sidechain so behavior is identical to
        // pre-sidechain builds when nothing is wired.
        self.process_with_sidechain(
            input_buffers,
            output_buffers,
            channel_count,
            frame_count,
            std::ptr::null(),
            0,
            false,
        )
    }

    /// Process audio buffers with an optional sidechain input bus.
    ///
    /// Mirrors `process()` but accepts a second per-channel pointer array
    /// and a "connected" flag describing whether the host has anything
    /// routed to the sidechain slot in this render block. When
    /// `sidechain_connected` is false (or `sidechain_buffers` is null),
    /// backends that consume sidechain see silence.
    ///
    /// # Safety
    /// - `input_buffers` / `output_buffers` constraints from `process()`
    ///   apply.
    /// - When `sidechain_connected` is true and `sidechain_buffers` is
    ///   non-null, it must point to `sidechain_channel_count` valid
    ///   `*const f32` pointers, each with at least `frame_count` samples.
    pub unsafe fn process_with_sidechain(
        &mut self,
        input_buffers: *const *const f32,
        output_buffers: *const *mut f32,
        channel_count: u32,
        frame_count: u32,
        sidechain_buffers: *const *const f32,
        sidechain_channel_count: u32,
        sidechain_connected: bool,
    ) {
        let channel_count = channel_count as usize;
        let frame_count = frame_count as usize;
        let inputs = std::slice::from_raw_parts(input_buffers, channel_count);
        let outputs = std::slice::from_raw_parts(output_buffers, channel_count);

        let sidechain_channel_count = sidechain_channel_count as usize;
        let sidechain_slice: &[*const f32] =
            if sidechain_connected
                && !sidechain_buffers.is_null()
                && sidechain_channel_count > 0
            {
                std::slice::from_raw_parts(sidechain_buffers, sidechain_channel_count)
            } else {
                &[]
            };
        let sidechain = SidechainInput {
            inputs: sidechain_slice,
            channel_count: sidechain_slice.len(),
            connected: sidechain_connected && !sidechain_slice.is_empty(),
        };

        self.last_render_frame_count.store(frame_count as u32, Ordering::Relaxed);

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

        // Demo-gate target: 0 when unlicensed and the demo counter has expired,
        // 1 otherwise. The actual gain ramps toward this target over DEMO_FADE_MS
        // to avoid a click at the transition (see apply_demo_gain_envelope below).
        let demo_target: f32 = if !self.licensed.load(Ordering::Relaxed)
            && self.demo_samples_processed.load(Ordering::Relaxed)
                >= self.demo_limit_samples.load(Ordering::Relaxed)
        {
            0.0
        } else {
            1.0
        };

        // Fast path: once the fade-out has fully completed, short-circuit with a
        // hard zero-write so we skip backend processing entirely.
        if demo_target == 0.0 && self.demo_gain == 0.0 {
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

        // Snapshot parameters once per callback (lock-free atomic reads)
        let params = self.snapshot_params();
        // Snapshot bundle-private state (one Acquire load + Arc::clone).
        // Backends short-circuit re-deserialization when the generation
        // matches their cached one, so the steady-state cost is a single
        // atomic compare.
        let (state_gen, state_buf) = self.snapshot_state();
        let state = StateSnapshot {
            generation: state_gen,
            bytes: state_buf,
        };

        // Consume any pending stage request from the main thread before we
        // latch the phase for this callback. This is where FADE_IN → FADE_OUT
        // gain-preserving transitions happen, so rapid preset switches don't
        // click mid-fade.
        self.apply_pending_stage();
        // Drive the swap state machine into FADE_OUT (and run the watchdog)
        // if Swift has bracketed this callback with begin_preset_transition.
        // This must run after apply_pending_stage so a stage request arriving
        // in the same callback sees the FADE_OUT phase we set here.
        self.apply_transition_state(frame_count as u32);
        let phase = self.swap_phase.load(Ordering::Acquire);

        // Try backend processing — use try_lock to never block the render thread.
        // If the main thread is briefly holding the lock (e.g. inject_nam_slot), we
        // fall through to passthrough below.
        if let Ok(mut guard) = self.backend.try_lock() {
            let mut produced = false;

            if let Some(ref mut backend) = *guard {
                let t0 = std::time::Instant::now();
                let ok = backend.process(inputs, outputs, channel_count, frame_count, self.sample_rate, &params, &self.transport, sidechain, &state);
                // Ensure at least 1µs so sub-microsecond calls are still visible
                let elapsed_us = (t0.elapsed().as_micros() as u32).max(1);
                self.update_profiler(elapsed_us);
                // Track WASM linear memory size (single pointer read, ~0 overhead)
                let mem = backend.memory_bytes();
                if mem > 0 {
                    self.wasm_memory_bytes.store(mem, Ordering::Relaxed);
                }
                if ok {
                    Self::safety_clamp(outputs, channel_count, frame_count);
                    produced = true;

                    // Recovery: if the previous block errored, clear the
                    // backend's and kernel's error state on the first
                    // successful render. Without this, a transient failure
                    // would leave the editor's gutter marker stuck until
                    // the user reloads. Bumps `error_generation` so Swift's
                    // 10 Hz poll picks up the clear on the next tick.
                    if self.had_error_last_block.load(Ordering::Relaxed) {
                        backend.clear_last_error();
                        if self.update_last_error_try(None) {
                            self.had_error_last_block.store(false, Ordering::Relaxed);
                        }
                    }
                } else {
                    // Backend failed — capture error before dropping the &mut borrow.
                    // `try_lock` so the audio thread doesn't block on the main
                    // thread; on contention we drop this block's error report
                    // and the next failing block will set it again.
                    if let Some(err) = backend.last_error() {
                        self.update_last_error_try(Some(err.to_string()));
                    }
                    self.had_error_last_block.store(true, Ordering::Relaxed);
                }
                // Snapshot script-published telemetry into the kernel's
                // atomic store. Single-writer (audio thread, here) /
                // multi-reader (Swift display-link). Even on backend
                // failure we sample so transient writes from before the
                // crash aren't lost; backends that publish nothing have
                // a no-op `read_telemetry` and the snapshot stays zero.
                let mut tele = [0.0_f32; crate::params::TELEMETRY_LEN];
                backend.read_telemetry(&mut tele);
                for (slot, v) in self.telemetry.iter().zip(tele.iter()) {
                    slot.store(v.to_bits(), Ordering::Relaxed);
                }
                // Per-vector-slot harvest. try_lock only — if the UI
                // thread is mid-read, skip this block's vector update
                // rather than stall the audio thread. Stale-by-one-block
                // is fine; the next callback will catch up.
                if let Ok(mut vec_guard) = self.vec_telemetry.try_lock() {
                    let state = &mut *vec_guard;
                    let max_frames = state.max_frames;
                    let len = frame_count.min(max_frames);
                    if len > 0 && !state.rings.is_empty() {
                        // Split-borrow `state` so we can mutably write
                        // `scratch` while holding shared refs to the
                        // ring + seq + counter Vecs.
                        let rings = &state.rings;
                        let seqs = &state.seqs;
                        let last_frame_counts = &state.last_frame_counts;
                        let scratch = &mut state.scratch[..len];
                        for slot in 0..rings.len() {
                            let ring = match &rings[slot] {
                                Some(r) => r,
                                None => continue,
                            };
                            // Seqlock writer: mark in-progress (odd),
                            // copy, mark stable (even). Even though
                            // the surrounding mutex serializes
                            // readers vs writer today, publishing the
                            // counter lets a future lock-free reader
                            // path detect a torn read.
                            seqs[slot].fetch_add(1, Ordering::Release);
                            // Reset scratch in case the backend writes
                            // fewer than `len` samples (defensive — most
                            // backends fill the full slice).
                            for v in scratch.iter_mut() { *v = 0.0; }
                            backend.read_telemetry_vec(slot, len, scratch);
                            for i in 0..len {
                                ring[i].store(scratch[i].to_bits(), Ordering::Relaxed);
                            }
                            last_frame_counts[slot]
                                .store(len as u32, Ordering::Release);
                            seqs[slot].fetch_add(1, Ordering::Release);
                        }
                    }
                }
            }

            if !produced {
                // No backend yet, or backend errored — passthrough so the user
                // hears something. The fade envelope still applies on top.
                Self::passthrough(inputs, outputs, channel_count, frame_count);
            }

            // Apply the swap declick envelope (if any). This must run *after*
            // processing so the envelope shapes the actual audio that will be
            // emitted, regardless of whether it came from the backend or
            // passthrough fallback.
            if phase != SWAP_PHASE_IDLE {
                self.apply_swap_envelope(outputs, channel_count, frame_count, phase);
                // If the fade just hit zero, transition the state machine.
                if self.swap_fade_remaining.load(Ordering::Relaxed) == 0 {
                    match phase {
                        SWAP_PHASE_FADE_OUT => {
                            // Only swap when pending actually holds a freshly-
                            // staged backend. Without this gate, a held
                            // transition (parked in FADE_OUT/rem=0 across
                            // many callbacks) would call perform_swap_locked
                            // every callback — and after the first swap,
                            // pending holds the parked OLD, so subsequent
                            // calls would oscillate live ↔ pending and leave
                            // a non-deterministic backend in `live` when the
                            // transition ends. Reading the fresh flag with
                            // AcqRel swap atomically claims the swap right.
                            let do_swap = self
                                .pending_backend_fresh
                                .swap(false, Ordering::AcqRel);
                            let depth = self.transition_depth.load(Ordering::Acquire);
                            if do_swap {
                                let installed = self.perform_swap_locked(&mut *guard);
                                if !installed {
                                    // `pending_backend` was contended (e.g.
                                    // main thread mid-inject_nam_slot). Restore
                                    // the fresh-stage signal so the next
                                    // callback retries — otherwise the staged
                                    // backend would be stranded forever.
                                    self.pending_backend_fresh
                                        .store(true, Ordering::Release);
                                } else if depth > 0 {
                                    // Held transition — park back in FADE_OUT
                                    // at silence. perform_swap_locked just
                                    // advanced us to FADE_IN; override.
                                    self.swap_fade_remaining.store(0, Ordering::Relaxed);
                                    self.swap_phase
                                        .store(SWAP_PHASE_FADE_OUT, Ordering::Release);
                                }
                            } else if depth == 0 {
                                // No fresh backend AND transition has ended:
                                // advance to FADE_IN with whatever is in
                                // `live` (mirrors the pending-is-none branch
                                // of perform_swap_locked) so we ramp audio
                                // back up. Don't touch pending — it holds
                                // the parked OLD for deferred drop.
                                let len = self.swap_fade_length.load(Ordering::Relaxed);
                                self.swap_fade_remaining.store(len, Ordering::Relaxed);
                                self.swap_phase
                                    .store(SWAP_PHASE_FADE_IN, Ordering::Release);
                            }
                            // else: held transition with no fresh stage —
                            // stay parked in FADE_OUT/rem=0.
                        }
                        SWAP_PHASE_FADE_IN => {
                            self.swap_phase.store(SWAP_PHASE_IDLE, Ordering::Release);
                        }
                        _ => {}
                    }
                }
            }

            // Declick the demo gate: ramp `demo_gain` toward `demo_target` and
            // multiply into the outputs. No-op when fully open (common case).
            Self::apply_demo_gain_envelope(
                &mut self.demo_gain,
                self.demo_fade_step,
                outputs,
                channel_count,
                frame_count,
                demo_target,
            );

            // Capture output audio for spectrogram (after processing + envelope)
            if capturing {
                self.capture_to_ring(Self::as_const_ptrs(outputs), channel_count, frame_count, &self.output_ring);
            }
            // Increment demo counter only if output is non-silent
            if !self.licensed.load(Ordering::Relaxed)
                && Self::buffer_peak(Self::as_const_ptrs(outputs), channel_count, frame_count)
                    >= DEMO_SILENCE_THRESHOLD
            {
                self.demo_samples_processed
                    .fetch_add(frame_count as u64, Ordering::Relaxed);
            }
            return;
        }

        // Fallback: backend lock contended — passthrough and still apply envelope.
        // The actual swap will happen on the next callback when we re-acquire it.
        Self::passthrough(inputs, outputs, channel_count, frame_count);
        if phase != SWAP_PHASE_IDLE {
            self.apply_swap_envelope(outputs, channel_count, frame_count, phase);
            // Don't transition state here — we couldn't perform the swap without
            // the backend lock, so leave the phase machine to the next callback.
        }
        // Declick the demo gate on the fallback path too.
        Self::apply_demo_gain_envelope(
            &mut self.demo_gain,
            self.demo_fade_step,
            outputs,
            channel_count,
            frame_count,
            demo_target,
        );
        // Capture output (same as input during passthrough, but envelope may have scaled it)
        if capturing {
            self.capture_to_ring(Self::as_const_ptrs(outputs), channel_count, frame_count, &self.output_ring);
        }
        // Increment demo counter only if output is non-silent
        if !self.licensed.load(Ordering::Relaxed)
            && Self::buffer_peak(Self::as_const_ptrs(outputs), channel_count, frame_count)
                >= DEMO_SILENCE_THRESHOLD
        {
            self.demo_samples_processed
                .fetch_add(frame_count as u64, Ordering::Relaxed);
        }
    }

    /// Apply the demo-gate fade envelope to output buffers in place, ramping
    /// `*demo_gain` toward `target` by `step` per sample and multiplying each
    /// output sample by the current gain. Fast-path no-op when `*demo_gain` is
    /// already `1.0` and the target is also `1.0` (the common licensed / demo-
    /// not-yet-expired case).
    ///
    /// Static (takes `&mut f32` instead of `&mut self`) so it can be called from
    /// inside the backend-mutex-guard scope without borrow conflicts.
    ///
    /// # Safety
    /// - Each pointer in `outputs` must point to at least `frame_count` writable f32 samples.
    unsafe fn apply_demo_gain_envelope(
        demo_gain: &mut f32,
        step: f32,
        outputs: &[*mut f32],
        channel_count: usize,
        frame_count: usize,
        target: f32,
    ) {
        if *demo_gain == 1.0 && target == 1.0 {
            // Hot path: demo gate fully open and staying open — nothing to do.
            return;
        }
        for frame in 0..frame_count {
            if *demo_gain < target {
                *demo_gain = (*demo_gain + step).min(target);
            } else if *demo_gain > target {
                *demo_gain = (*demo_gain - step).max(target);
            }
            let g = *demo_gain;
            for ch in 0..channel_count {
                *outputs[ch].add(frame) *= g;
            }
        }
    }

    /// Apply a linear fade envelope to the output buffers in place and decrement
    /// `swap_fade_remaining` by `frame_count` (saturating at zero). Called from
    /// the audio thread inside `process()`.
    ///
    /// Phase semantics:
    /// - `SWAP_PHASE_FADE_OUT`: gain ramps from `rem/len` toward `0`.
    /// - `SWAP_PHASE_FADE_IN`:  gain ramps from `1 - rem/len` toward `1`.
    /// - Other phases: no-op.
    ///
    /// The per-sample gain is clamped to `[0, 1]` so even if `rem` reached zero
    /// mid-buffer the trailing samples sit at the boundary value (silence for
    /// fade-out, full level for fade-in).
    unsafe fn apply_swap_envelope(
        &self,
        outputs: &[*mut f32],
        channel_count: usize,
        frame_count: usize,
        phase: u8,
    ) {
        let len = self.swap_fade_length.load(Ordering::Relaxed);
        if len == 0 {
            // Defensive: nothing to fade — transition immediately.
            self.swap_fade_remaining.store(0, Ordering::Relaxed);
            return;
        }
        let inv_len = 1.0f32 / len as f32;
        let rem_start = self.swap_fade_remaining.load(Ordering::Relaxed);

        let (mut gain, gain_step) = match phase {
            SWAP_PHASE_FADE_OUT => (rem_start as f32 * inv_len, -inv_len),
            SWAP_PHASE_FADE_IN => (1.0f32 - rem_start as f32 * inv_len, inv_len),
            _ => return,
        };

        for frame in 0..frame_count {
            let g = gain.clamp(0.0, 1.0);
            for ch in 0..channel_count {
                *outputs[ch].add(frame) *= g;
            }
            gain += gain_step;
        }

        let new_rem = rem_start.saturating_sub(frame_count as u32);
        self.swap_fade_remaining.store(new_rem, Ordering::Relaxed);
    }

    /// Perform the actual backend swap on the audio thread. Called when fade-out
    /// has reached zero. Caller must hold a `MutexGuard` for `self.backend` so we
    /// can mutate the live slot in place.
    ///
    /// Returns `true` if the swap completed (or there was nothing pending to
    /// install — the no-op case still counts as "done"). Returns `false` when
    /// `pending_backend` is contended (e.g. main thread mid-`inject_nam_slot`)
    /// — the caller must keep the staged-fresh signal high so a later
    /// callback retries instead of dropping the new backend on the floor.
    ///
    /// On success, the previously live backend is parked back into
    /// `pending_backend` so the *next* main-thread `load_*` call drops it on a
    /// non-real-time thread (avoiding allocator/GIL work on the audio thread).
    fn perform_swap_locked(&self, live: &mut Option<Box<dyn Backend>>) -> bool {
        let Ok(mut pending) = self.pending_backend.try_lock() else {
            // Contended — caller must restore the fresh-stage signal.
            return false;
        };
        if pending.is_none() {
            // No backend staged — nothing to install. Transition straight to
            // fade-in so we don't get stuck in fade-out forever.
            let len = self.swap_fade_length.load(Ordering::Relaxed);
            self.swap_fade_remaining.store(len, Ordering::Relaxed);
            self.swap_phase
                .store(SWAP_PHASE_FADE_IN, Ordering::Release);
            return true;
        }
        // Move new → live, old → pending (where main thread will drop it).
        std::mem::swap(live, &mut *pending);

        // Apply staged param defaults atomically with the swap, so the new
        // backend's first frame already sees its declared defaults.
        if let Ok(mut defaults) = self.pending_param_defaults.try_lock() {
            if let Some(d) = defaults.take() {
                for (i, &val) in d.iter().enumerate().take(PARAM_COUNT) {
                    self.params[i].store(val.to_bits(), Ordering::Relaxed);
                }
            }
        }

        // Begin the fade-in half of the envelope.
        let len = self.swap_fade_length.load(Ordering::Relaxed);
        self.swap_fade_remaining.store(len, Ordering::Relaxed);
        self.swap_phase
            .store(SWAP_PHASE_FADE_IN, Ordering::Release);
        true
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

    /// Reinterpret a `&[*mut f32]` slice as `&[*const f32]` (same layout, no allocation).
    #[inline]
    fn as_const_ptrs(outputs: &[*mut f32]) -> &[*const f32] {
        // SAFETY: *mut T and *const T have identical layout per Rust reference.
        unsafe { std::slice::from_raw_parts(outputs.as_ptr() as *const *const f32, outputs.len()) }
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

    /// `ctx.inputs` is exposed as a 2D `(n_channels, max_frames)` ndarray
    /// (not a list of per-channel arrays). The script writes the ndim into
    /// the first output sample; passthrough fallback would show the input.
    #[test]
    fn test_python_ctx_inputs_is_2d_ndarray() {
        let (python_home, _) = match test_python_paths() {
            Some(paths) => paths,
            None => {
                eprintln!("Skipping: bundled Python runtime not found");
                return;
            }
        };
        // Encode ndim and shape into samples within [-1, 1] (the kernel's
        // safety-limiter range), then read back and decode. The script
        // writes 0.1 * ndim and 0.1 * shape[0] / shape[1] so a 2D (2, 1024)
        // ctx produces output_l[0..3] = [0.2, 0.2, 102.4 → clamped to 1.0]
        // — but we only assert on positions that stay in range.
        let script = write_temp_script(
            "import numpy as np\ndef process(ctx):\n    ctx.outputs[0][0] = ctx.inputs.ndim * 0.1\n    ctx.outputs[0][1] = ctx.inputs.shape[0] * 0.1\n    ctx.outputs[1][0] = 1.0 if ctx.inputs[0].flags.c_contiguous else -1.0\n    ctx.outputs[1][1] = 0.5 if isinstance(ctx.inputs, np.ndarray) else -0.5\n",
        );
        let mut kernel = DSPKernel::new();
        assert!(kernel.load_script(&python_home, script.to_str().unwrap()));
        kernel.initialize(2, 2, 44100.0);

        let input_l: [f32; 4] = [0.0, 0.0, 0.0, 0.0];
        let input_r: [f32; 4] = [0.0, 0.0, 0.0, 0.0];
        let mut output_l: [f32; 4] = [0.0; 4];
        let mut output_r: [f32; 4] = [0.0; 4];
        let input_ptrs: [*const f32; 2] = [input_l.as_ptr(), input_r.as_ptr()];
        let output_ptrs: [*mut f32; 2] = [output_l.as_mut_ptr(), output_r.as_mut_ptr()];
        unsafe {
            kernel.process(input_ptrs.as_ptr(), output_ptrs.as_ptr(), 2, 4);
        }
        assert!(
            kernel.last_error().is_none(),
            "python raised: {:?}",
            kernel.last_error()
        );
        // ctx.inputs.ndim == 2 → 0.2
        assert!((output_l[0] - 0.2).abs() < 1e-6, "ndim should be 2 (got {})", output_l[0] * 10.0);
        // ctx.inputs.shape[0] == 2 (channel count) → 0.2
        assert!((output_l[1] - 0.2).abs() < 1e-6, "shape[0] should be 2 (got {})", output_l[1] * 10.0);
        // Row 0 of a C-contiguous PyArray2 must be contiguous → 1.0
        assert_eq!(output_r[0], 1.0, "ctx.inputs[0] should be c_contiguous");
        // ctx.inputs should be a numpy ndarray → 0.5
        assert_eq!(output_r[1], 0.5, "ctx.inputs should be a numpy ndarray");
        std::fs::remove_file(script).ok();
    }

    /// Verify cross-channel numpy vectorization: `ctx.outputs[:] = ctx.inputs * 0.5`
    /// works because the arrays are 2D. With the previous list-of-arrays
    /// shape this would raise; the kernel would fall through to passthrough.
    #[test]
    fn test_python_cross_channel_vectorized() {
        let (python_home, _) = match test_python_paths() {
            Some(paths) => paths,
            None => {
                eprintln!("Skipping: bundled Python runtime not found");
                return;
            }
        };
        let script = write_temp_script(
            "import numpy as np\ndef process(ctx):\n    ctx.outputs[:] = ctx.inputs * 0.5\n",
        );
        let mut kernel = DSPKernel::new();
        assert!(kernel.load_script(&python_home, script.to_str().unwrap()));
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
        assert!(
            kernel.last_error().is_none(),
            "python raised: {:?}",
            kernel.last_error()
        );
        assert_eq!(output_l, [0.5, 0.25, -0.5, 0.0]);
        assert_eq!(output_r, [0.1, 0.2, 0.3, 0.4]);
        std::fs::remove_file(script).ok();
    }

    /// After PR #2, ctx.inputs/outputs are sliced views of length
    /// frame_count, not the underlying max_frames buffer. Each row's length
    /// must equal frame_count for the block.
    #[test]
    fn test_python_ctx_views_pre_sliced_to_frame_count() {
        let (python_home, _) = match test_python_paths() {
            Some(paths) => paths,
            None => {
                eprintln!("Skipping: bundled Python runtime not found");
                return;
            }
        };
        let script = write_temp_script(
            "import numpy as np\ndef process(ctx):\n    ctx.outputs[0][0] = len(ctx.inputs[0]) * 0.001\n    ctx.outputs[0][1] = ctx.inputs.shape[1] * 0.001\n    ctx.outputs[1][0] = len(ctx.outputs[0]) * 0.001\n    ctx.outputs[1][1] = ctx.outputs.shape[1] * 0.001\n",
        );
        let mut kernel = DSPKernel::new();
        assert!(kernel.load_script(&python_home, script.to_str().unwrap()));
        kernel.initialize(2, 2, 44100.0);

        let input_l: [f32; 7] = [0.0; 7];
        let input_r: [f32; 7] = [0.0; 7];
        let mut output_l: [f32; 7] = [0.0; 7];
        let mut output_r: [f32; 7] = [0.0; 7];
        let input_ptrs: [*const f32; 2] = [input_l.as_ptr(), input_r.as_ptr()];
        let output_ptrs: [*mut f32; 2] = [output_l.as_mut_ptr(), output_r.as_mut_ptr()];
        unsafe {
            kernel.process(input_ptrs.as_ptr(), output_ptrs.as_ptr(), 2, 7);
        }
        assert!(
            kernel.last_error().is_none(),
            "python raised: {:?}",
            kernel.last_error()
        );
        // Each encoded value is frame_count * 0.001 = 7 * 0.001 = 0.007.
        assert!((output_l[0] - 0.007).abs() < 1e-5, "len(ctx.inputs[0]) should be 7 (got {})", output_l[0] * 1000.0);
        assert!((output_l[1] - 0.007).abs() < 1e-5, "ctx.inputs.shape[1] should be 7 (got {})", output_l[1] * 1000.0);
        assert!((output_r[0] - 0.007).abs() < 1e-5, "len(ctx.outputs[0]) should be 7 (got {})", output_r[0] * 1000.0);
        assert!((output_r[1] - 0.007).abs() < 1e-5, "ctx.outputs.shape[1] should be 7 (got {})", output_r[1] * 1000.0);
        std::fs::remove_file(script).ok();
    }

    /// Out-of-bounds index assignment on the pre-sliced view raises
    /// IndexError. Under PR #2, ctx.outputs[ch] has length frame_count, so
    /// writing past it surfaces immediately. The kernel falls back to
    /// passthrough on the exception.
    #[test]
    fn test_python_oob_index_assignment_raises() {
        let (python_home, _) = match test_python_paths() {
            Some(paths) => paths,
            None => {
                eprintln!("Skipping: bundled Python runtime not found");
                return;
            }
        };
        // Write to ctx.outputs[0][ctx.frame_count] — one past the end.
        let script = write_temp_script(
            "import numpy as np\ndef process(ctx):\n    ctx.outputs[0][ctx.frame_count] = 0.9\n",
        );
        let mut kernel = DSPKernel::new();
        assert!(kernel.load_script(&python_home, script.to_str().unwrap()));
        kernel.initialize(1, 1, 44100.0);

        let input: [f32; 4] = [0.5, 0.5, 0.5, 0.5];
        let mut output: [f32; 4] = [0.0; 4];
        let ip: *const f32 = input.as_ptr();
        let op: *mut f32 = output.as_mut_ptr();
        unsafe { kernel.process(&ip, &op, 1, 4); }

        // Passthrough: input copied to output. The error is captured.
        assert_eq!(output, [0.5, 0.5, 0.5, 0.5]);
        let err = kernel.last_error().expect("oob assignment should set last_error");
        assert!(
            err.contains("IndexError") || err.contains("index"),
            "expected IndexError in last_error, got: {err}"
        );
        std::fs::remove_file(script).ok();
    }

    /// Negative test: a script that rebinds ctx.outputs to a fresh array
    /// does NOT change the host's output — Rust reads from the unchanged
    /// backing array. Locks the contract so a future "fix" doesn't quietly
    /// change it.
    #[test]
    fn test_python_outputs_rebinding_silently_discarded() {
        let (python_home, _) = match test_python_paths() {
            Some(paths) => paths,
            None => {
                eprintln!("Skipping: bundled Python runtime not found");
                return;
            }
        };
        // Rebind ctx.outputs to a fresh array, then write a known value into
        // it. The backing array Rust reads from is unchanged.
        let script = write_temp_script(
            "import numpy as np\ndef process(ctx):\n    ctx.outputs = np.zeros_like(ctx.outputs)\n    ctx.outputs[:] = 0.9\n",
        );
        let mut kernel = DSPKernel::new();
        assert!(kernel.load_script(&python_home, script.to_str().unwrap()));
        kernel.initialize(1, 1, 44100.0);

        let input: [f32; 4] = [0.1, 0.2, 0.3, 0.4];
        let mut output: [f32; 4] = [0.0; 4];
        let ip: *const f32 = input.as_ptr();
        let op: *mut f32 = output.as_mut_ptr();
        unsafe { kernel.process(&ip, &op, 1, 4); }

        // Backing array was never written to — it stays zero (allocated
        // fresh by allocate_py_arrays). Host hears silence.
        assert_eq!(output, [0.0, 0.0, 0.0, 0.0]);
        assert!(
            kernel.last_error().is_none(),
            "no error expected (rebinding is silent), got: {:?}",
            kernel.last_error()
        );
        std::fs::remove_file(script).ok();
    }

    /// A render block with `frame_count == 0` must not panic. The prefix-
    /// slice cache uses `u32::MAX` as its "uninitialized" sentinel so a
    /// real zero-frame block still triggers the rebuild path on the very
    /// first call. Hosts can pass zero frames at transport edges; previously
    /// this would `.unwrap()` on `None` and crash the audio thread.
    #[test]
    fn test_python_zero_frame_count_does_not_panic() {
        let (python_home, _) = match test_python_paths() {
            Some(paths) => paths,
            None => {
                eprintln!("Skipping: bundled Python runtime not found");
                return;
            }
        };
        let script = write_temp_script(
            "import numpy as np\ndef process(ctx):\n    np.copyto(ctx.outputs, ctx.inputs)\n",
        );
        let mut kernel = DSPKernel::new();
        assert!(kernel.load_script(&python_home, script.to_str().unwrap()));
        kernel.initialize(1, 4, 44100.0);

        let input: [f32; 4] = [0.0; 4];
        let mut output: [f32; 4] = [0.0; 4];
        let ip: *const f32 = input.as_ptr();
        let op: *mut f32 = output.as_mut_ptr();
        // Drive a 0-frame block FIRST. With the old `cached_prefix_for_frames: 0`
        // initializer, this would skip the rebuild and unwrap None.
        unsafe { kernel.process(&ip, &op, 1, 0); }
        assert!(
            kernel.last_error().is_none(),
            "0-frame block should not raise, got: {:?}",
            kernel.last_error()
        );
        // Follow-up non-zero block must also work.
        let input2: [f32; 4] = [0.1, 0.2, 0.3, 0.4];
        let ip2: *const f32 = input2.as_ptr();
        unsafe { kernel.process(&ip2, &op, 1, 4); }
        assert_eq!(output, [0.1, 0.2, 0.3, 0.4]);
        std::fs::remove_file(script).ok();
    }

    /// PR #4: `error_generation` bumps on the first failing block. Swift's
    /// poll uses this delta to know it needs to re-read `last_error`.
    #[test]
    fn test_error_generation_bumps_on_render_failure() {
        let (python_home, _) = match test_python_paths() {
            Some(paths) => paths,
            None => {
                eprintln!("Skipping: bundled Python runtime not found");
                return;
            }
        };
        let script = write_temp_script(
            "import numpy as np\ndef process(ctx):\n    raise ValueError('boom')\n",
        );
        let mut kernel = DSPKernel::new();
        let gen_before_load = kernel.error_generation();
        assert!(kernel.load_script(&python_home, script.to_str().unwrap()));
        // Successful load with `last_error` previously None — should not bump
        // (state didn't change).
        let gen_after_load = kernel.error_generation();
        assert_eq!(
            gen_after_load, gen_before_load,
            "successful load on clean state should not bump generation"
        );

        kernel.initialize(1, 1, 44100.0);
        let input: [f32; 4] = [0.5, 0.5, 0.5, 0.5];
        let mut output: [f32; 4] = [0.0; 4];
        let ip: *const f32 = input.as_ptr();
        let op: *mut f32 = output.as_mut_ptr();
        unsafe { kernel.process(&ip, &op, 1, 4); }

        // After one failing block, the counter advanced and last_error is Some.
        assert!(
            kernel.error_generation() > gen_after_load,
            "error_generation should bump on raise"
        );
        assert!(kernel.last_error().is_some(), "last_error should be Some");
        std::fs::remove_file(script).ok();
    }

    /// PR #4: `error_generation` bumps again when the kernel auto-clears the
    /// stuck error on the first successful render after a failure. This is
    /// what stops the editor's gutter marker from getting stuck.
    #[test]
    fn test_error_generation_bumps_on_recovery_clear() {
        let (python_home, _) = match test_python_paths() {
            Some(paths) => paths,
            None => {
                eprintln!("Skipping: bundled Python runtime not found");
                return;
            }
        };
        // Script raises only when ctx.params[0] >= 0.5 (default 0). We'll
        // drive the param to trigger the raise, then back down to recover.
        let script = write_temp_script(
            "import numpy as np\ndef process(ctx):\n    if ctx.params[0] >= 0.5:\n        raise ValueError('intermittent')\n    ctx.outputs[:] = ctx.inputs\n",
        );
        let mut kernel = DSPKernel::new();
        assert!(kernel.load_script(&python_home, script.to_str().unwrap()));
        kernel.initialize(1, 1, 44100.0);

        let input: [f32; 4] = [0.5, 0.5, 0.5, 0.5];
        let mut output: [f32; 4] = [0.0; 4];
        let ip: *const f32 = input.as_ptr();
        let op: *mut f32 = output.as_mut_ptr();

        // Drive params[0] high → script raises.
        kernel.set_parameter(0, 0.9);
        unsafe { kernel.process(&ip, &op, 1, 4); }
        let gen_after_failure = kernel.error_generation();
        assert!(kernel.last_error().is_some(), "should have error after raise");

        // Drive params[0] low → script succeeds. Kernel detects the
        // transition from had_error_last_block=true and clears.
        kernel.set_parameter(0, 0.0);
        unsafe { kernel.process(&ip, &op, 1, 4); }
        assert!(
            kernel.error_generation() > gen_after_failure,
            "generation should bump on auto-clear"
        );
        assert!(
            kernel.last_error().is_none(),
            "last_error should clear after recovery, got: {:?}",
            kernel.last_error()
        );
        std::fs::remove_file(script).ok();
    }

    /// PR #4: `error_generation` bumps on script reload that clears a prior
    /// load failure. Same Swift-side mechanism handles both render-time and
    /// load-time clears.
    #[test]
    fn test_error_generation_bumps_on_reload_clear() {
        let (python_home, _) = match test_python_paths() {
            Some(paths) => paths,
            None => {
                eprintln!("Skipping: bundled Python runtime not found");
                return;
            }
        };
        let bad_script = write_temp_script(
            "this is not valid python at all\ndef process",
        );
        let good_script = write_temp_script(
            "import numpy as np\ndef process(ctx):\n    pass\n",
        );

        let mut kernel = DSPKernel::new();
        // First load fails; generation bumps and last_error is Some.
        let r1 = kernel.load_script(&python_home, bad_script.to_str().unwrap());
        assert!(!r1, "bad script should fail to load");
        let gen_after_fail = kernel.error_generation();
        assert!(gen_after_fail > 0, "load failure should bump generation");
        assert!(kernel.last_error().is_some());

        // Second load succeeds; clears last_error → generation bumps again.
        let r2 = kernel.load_script(&python_home, good_script.to_str().unwrap());
        assert!(r2, "clean script should load");
        assert!(
            kernel.error_generation() > gen_after_fail,
            "successful reload should bump generation when clearing prior error"
        );
        assert!(kernel.last_error().is_none());

        std::fs::remove_file(bad_script).ok();
        std::fs::remove_file(good_script).ok();
    }

    /// PR #4: `update_last_error_try` reports `true` only when it acquired
    /// the lock. The audio-thread recovery branch gates its `had_error_last_block`
    /// clear on this return so a contended write doesn't desynchronize the
    /// flag from `last_error` (which would suppress retry forever and leave
    /// a stale error in the UI).
    #[test]
    fn test_update_last_error_try_signals_lock_acquisition() {
        let kernel = DSPKernel::new();

        // Uncontended: lock acquires → true, even when the value didn't
        // change. The "no-op write" case (already-equal) still reflects
        // committed state, so the caller can safely clear flags.
        assert!(kernel.update_last_error_try(None));
        assert!(kernel.update_last_error_try(Some("first".to_string())));
        assert!(
            kernel.update_last_error_try(Some("first".to_string())),
            "no-op (same value) must return true under post-fix semantics"
        );

        // Contended: an outstanding `last_error.lock()` blocks try_lock →
        // we get false, and the recovery-branch caller will not clear
        // its had_error_last_block flag (tested via integration above).
        {
            let _guard = kernel.last_error.lock().unwrap();
            assert!(
                !kernel.update_last_error_try(Some("second".to_string())),
                "contended try_lock must return false"
            );
        }
        // After the guard drops, the call succeeds again.
        assert!(kernel.update_last_error_try(Some("third".to_string())));
    }

/// PR #4: a failed reload must reset `had_error_last_block`. Without
    /// this, the next passthrough block (which returns `ok=true`) would
    /// see the stale `true` flag from the prior runtime failure and let
    /// the recovery branch wipe the freshly-written load-error string.
    #[test]
    fn test_failed_reload_resets_had_error_flag() {
        let (python_home, _) = match test_python_paths() {
            Some(paths) => paths,
            None => {
                eprintln!("Skipping: bundled Python runtime not found");
                return;
            }
        };
        let raising_script = write_temp_script(
            "import numpy as np\ndef process(ctx):\n    raise ValueError('runtime boom')\n",
        );
        let bad_syntax_script = write_temp_script(
            "this is not valid python at all\ndef process",
        );

        let mut kernel = DSPKernel::new();
        assert!(kernel.load_script(&python_home, raising_script.to_str().unwrap()));
        kernel.initialize(1, 4, 44100.0);

        let input: [f32; 4] = [0.1, 0.2, 0.3, 0.4];
        let mut output: [f32; 4] = [0.0; 4];
        let ip: *const f32 = input.as_ptr();
        let op: *mut f32 = output.as_mut_ptr();

        // Render → runtime error sets had_error_last_block to true.
        unsafe { kernel.process(&ip, &op, 1, 4); }
        assert!(
            kernel.had_error_last_block.load(Ordering::Relaxed),
            "runtime error should set had_error_last_block"
        );

        // Failed reload — the fix wires `.store(false, …)` into the Err arm
        // of `load_script`. Without it the flag would stay `true`.
        let r = kernel.load_script(&python_home, bad_syntax_script.to_str().unwrap());
        assert!(!r, "bad-syntax script should fail to load");
        assert!(
            !kernel.had_error_last_block.load(Ordering::Relaxed),
            "failed reload must reset had_error_last_block"
        );
        assert!(
            kernel.last_error().is_some(),
            "failed reload should leave last_error set"
        );

        std::fs::remove_file(raising_script).ok();
        std::fs::remove_file(bad_syntax_script).ok();
    }

    /// PR #4: re-setting the same error string (e.g. a script that raises
    /// every block with an identical message) does NOT bump the counter
    /// after the first hit. Steady-state failure is one initial bump plus
    /// zero per-block bumps.
    #[test]
    fn test_error_generation_steady_state_no_repeated_bump() {
        let (python_home, _) = match test_python_paths() {
            Some(paths) => paths,
            None => {
                eprintln!("Skipping: bundled Python runtime not found");
                return;
            }
        };
        let script = write_temp_script(
            "import numpy as np\ndef process(ctx):\n    raise ValueError('same message every time')\n",
        );
        let mut kernel = DSPKernel::new();
        assert!(kernel.load_script(&python_home, script.to_str().unwrap()));
        kernel.initialize(1, 1, 44100.0);

        let input: [f32; 4] = [0.5; 4];
        let mut output: [f32; 4] = [0.0; 4];
        let ip: *const f32 = input.as_ptr();
        let op: *mut f32 = output.as_mut_ptr();

        unsafe { kernel.process(&ip, &op, 1, 4); }
        let gen_after_first = kernel.error_generation();
        for _ in 0..10 {
            unsafe { kernel.process(&ip, &op, 1, 4); }
        }
        assert_eq!(
            kernel.error_generation(),
            gen_after_first,
            "identical error message should not bump generation per block"
        );
        std::fs::remove_file(script).ok();
    }

    /// PR #3: ctx.params supports both dict-style and attribute-style read.
    /// Identical values returned from both surfaces.
    #[test]
    fn test_python_ctx_params_attr_access() {
        let (python_home, _) = match test_python_paths() {
            Some(paths) => paths,
            None => {
                eprintln!("Skipping: bundled Python runtime not found");
                return;
            }
        };
        let script = write_temp_script(
            "PARAMS = {'gain': {'min': 0.0, 'max': 1.0, 'default': 0.42, 'unit': ''}}\ndef process(ctx):\n    ok = ctx.params.gain == ctx.params['gain']\n    ctx.outputs[0][0] = 0.5 if ok else -0.5\n",
        );
        let mut kernel = DSPKernel::new();
        assert!(kernel.load_script(&python_home, script.to_str().unwrap()));
        kernel.initialize(1, 1, 44100.0);

        let input: [f32; 4] = [0.0; 4];
        let mut output: [f32; 4] = [0.0; 4];
        let ip: *const f32 = input.as_ptr();
        let op: *mut f32 = output.as_mut_ptr();
        unsafe { kernel.process(&ip, &op, 1, 4); }
        assert!(
            kernel.last_error().is_none(),
            "python raised: {:?}", kernel.last_error()
        );
        assert_eq!(output[0], 0.5, "ctx.params.gain should equal ctx.params['gain']");
        std::fs::remove_file(script).ok();
    }

    /// PR #3: unknown attribute access raises AttributeError. Script catches
    /// it and signals success via the output.
    #[test]
    fn test_python_ctx_params_unknown_attr_raises() {
        let (python_home, _) = match test_python_paths() {
            Some(paths) => paths,
            None => {
                eprintln!("Skipping: bundled Python runtime not found");
                return;
            }
        };
        let script = write_temp_script(
            "PARAMS = {'gain': {'min': 0.0, 'max': 1.0, 'default': 0.0, 'unit': ''}}\ndef process(ctx):\n    try:\n        _ = ctx.params.bogus\n        ctx.outputs[0][0] = -0.5\n    except AttributeError as e:\n        # Confirm the error message mentions the missing key AND lists declared params.\n        if 'bogus' in str(e) and 'gain' in str(e):\n            ctx.outputs[0][0] = 0.5\n        else:\n            ctx.outputs[0][0] = -0.7\n",
        );
        let mut kernel = DSPKernel::new();
        assert!(kernel.load_script(&python_home, script.to_str().unwrap()));
        kernel.initialize(1, 1, 44100.0);
        let input: [f32; 4] = [0.0; 4];
        let mut output: [f32; 4] = [0.0; 4];
        let ip: *const f32 = input.as_ptr();
        let op: *mut f32 = output.as_mut_ptr();
        unsafe { kernel.process(&ip, &op, 1, 4); }
        assert!(kernel.last_error().is_none(), "python raised: {:?}", kernel.last_error());
        assert_eq!(output[0], 0.5, "unknown attr should raise AttributeError citing both 'bogus' and 'gain'");
        std::fs::remove_file(script).ok();
    }

    /// PR #3: unknown key access raises KeyError with the same helpful
    /// "did you mean" message as the attribute path.
    #[test]
    fn test_python_ctx_params_unknown_key_raises() {
        let (python_home, _) = match test_python_paths() {
            Some(paths) => paths,
            None => {
                eprintln!("Skipping: bundled Python runtime not found");
                return;
            }
        };
        let script = write_temp_script(
            "PARAMS = {'gain': {'min': 0.0, 'max': 1.0, 'default': 0.0, 'unit': ''}}\ndef process(ctx):\n    try:\n        _ = ctx.params['bogus']\n        ctx.outputs[0][0] = -0.5\n    except KeyError as e:\n        msg = str(e)\n        if 'bogus' in msg and 'gain' in msg:\n            ctx.outputs[0][0] = 0.5\n        else:\n            ctx.outputs[0][0] = -0.7\n",
        );
        let mut kernel = DSPKernel::new();
        assert!(kernel.load_script(&python_home, script.to_str().unwrap()));
        kernel.initialize(1, 1, 44100.0);
        let input: [f32; 4] = [0.0; 4];
        let mut output: [f32; 4] = [0.0; 4];
        let ip: *const f32 = input.as_ptr();
        let op: *mut f32 = output.as_mut_ptr();
        unsafe { kernel.process(&ip, &op, 1, 4); }
        assert!(kernel.last_error().is_none(), "python raised: {:?}", kernel.last_error());
        assert_eq!(output[0], 0.5, "unknown key should raise KeyError citing both 'bogus' and 'gain'");
        std::fs::remove_file(script).ok();
    }

    /// PR #3: any write to ctx.params raises (attribute or subscript). Locks
    /// the read-only contract.
    #[test]
    fn test_python_ctx_params_readonly() {
        let (python_home, _) = match test_python_paths() {
            Some(paths) => paths,
            None => {
                eprintln!("Skipping: bundled Python runtime not found");
                return;
            }
        };
        let script = write_temp_script(
            "PARAMS = {'gain': {'min': 0.0, 'max': 1.0, 'default': 0.0, 'unit': ''}}\ndef process(ctx):\n    attr_raised = False\n    item_raised = False\n    try: ctx.params.gain = 0.0\n    except AttributeError: attr_raised = True\n    try: ctx.params['gain'] = 0.0\n    except TypeError: item_raised = True\n    ctx.outputs[0][0] = 0.5 if (attr_raised and item_raised) else -0.5\n",
        );
        let mut kernel = DSPKernel::new();
        assert!(kernel.load_script(&python_home, script.to_str().unwrap()));
        kernel.initialize(1, 1, 44100.0);
        let input: [f32; 4] = [0.0; 4];
        let mut output: [f32; 4] = [0.0; 4];
        let ip: *const f32 = input.as_ptr();
        let op: *mut f32 = output.as_mut_ptr();
        unsafe { kernel.process(&ip, &op, 1, 4); }
        assert!(kernel.last_error().is_none(), "python raised: {:?}", kernel.last_error());
        assert_eq!(output[0], 0.5, "both attr and subscript writes should raise");
        std::fs::remove_file(script).ok();
    }

    /// PR #3: keys/values/items/iteration all work and reflect declared params.
    #[test]
    fn test_python_ctx_params_iteration() {
        let (python_home, _) = match test_python_paths() {
            Some(paths) => paths,
            None => {
                eprintln!("Skipping: bundled Python runtime not found");
                return;
            }
        };
        let script = write_temp_script(
            "PARAMS = {'gain': {'min': 0.0, 'max': 1.0, 'default': 0.0, 'unit': ''}, 'mix': {'min': 0.0, 'max': 1.0, 'default': 0.0, 'unit': ''}}\ndef process(ctx):\n    keys = sorted(ctx.params.keys())\n    names_iter = sorted(list(ctx.params))\n    values_count = sum(1 for _ in ctx.params.values())\n    items_count = sum(1 for _ in ctx.params.items())\n    contains_ok = 'gain' in ctx.params and 'mix' in ctx.params\n    ok = (keys == ['gain', 'mix']\n          and names_iter == ['gain', 'mix']\n          and values_count == 2\n          and items_count == 2\n          and contains_ok\n          and len(ctx.params) == 2)\n    ctx.outputs[0][0] = 0.5 if ok else -0.5\n",
        );
        let mut kernel = DSPKernel::new();
        assert!(kernel.load_script(&python_home, script.to_str().unwrap()));
        kernel.initialize(1, 1, 44100.0);
        let input: [f32; 4] = [0.0; 4];
        let mut output: [f32; 4] = [0.0; 4];
        let ip: *const f32 = input.as_ptr();
        let op: *mut f32 = output.as_mut_ptr();
        unsafe { kernel.process(&ip, &op, 1, 4); }
        assert!(kernel.last_error().is_none(), "python raised: {:?}", kernel.last_error());
        assert_eq!(output[0], 0.5, "all iteration methods should work");
        std::fs::remove_file(script).ok();
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
            "import numpy as np\ndef process(ctx):\n    raise RuntimeError('intentional error')\n",
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
            "import numpy as np\ndef process(ctx):\n    raise ValueError('boom')\n",
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
            "import numpy as np\ndef process(ctx):\n    for ch in range(len(ctx.inputs)):\n        ctx.outputs[ch][:ctx.frame_count] = ctx.inputs[ch][:ctx.frame_count] * 0.5\n",
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
            "import numpy as np\ndef process(ctx):\n    for ch in range(len(ctx.inputs)):\n        ctx.outputs[ch][:ctx.frame_count] = ctx.inputs[ch][:ctx.frame_count] * 0.25\n",
        );
        assert!(kernel.load_script(&python_home, script_quarter.to_str().unwrap()));
        kernel.initialize(1, 1, 44100.0);

        // Drive enough samples to complete the swap fade envelope
        // (~5ms fade-out + ~5ms fade-in at 44.1 kHz ≈ 440 samples). The audio
        // thread performs the actual backend swap at end-of-buffer, so we
        // process multiple chunks until the new backend's steady-state output
        // is visible.
        let chunk_input = vec![1.0f32; 256];
        let mut chunk_output = vec![0.0f32; 256];
        for _ in 0..6 {
            chunk_output.fill(0.0);
            let cip: *const f32 = chunk_input.as_ptr();
            let cop: *mut f32 = chunk_output.as_mut_ptr();
            unsafe { kernel.process(&cip, &cop, 1, 256); }
        }
        let tail = &chunk_output[chunk_output.len() - 4..];
        assert_eq!(tail, &[0.25, 0.25, 0.25, 0.25]);

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
            write_temp_script("import nonexistent_module_xyz\ndef process(i,o,f,s,_p,_t,_tel): pass\n");
        let mut kernel = DSPKernel::new();
        let result = kernel.load_script(&python_home, script.to_str().unwrap());
        assert!(!result);
        assert!(kernel.last_error().is_some());
        std::fs::remove_file(script).ok();
    }

    /// Pin the arity policy: only `def process(ctx):` (1-arg) is
    /// accepted. Everything else fails at load time with a clear,
    /// actionable error pointing to the new shape.
    #[test]
    fn test_load_script_rejects_invalid_arity_signatures() {
        let (python_home, _) = match test_python_paths() {
            Some(paths) => paths,
            None => {
                eprintln!("Skipping: bundled Python runtime not found");
                return;
            }
        };

        let cases: &[(&str, &str)] = &[
            ("0-arg",         "def process(): pass\n"),
            ("4-arg legacy", "def process(i, o, f, s): pass\n"),
            ("5-arg",         "def process(i, o, f, s, p): pass\n"),
            ("6-arg",         "def process(i, o, f, s, p, t): pass\n"),
            ("7-arg legacy", "def process(i, o, f, s, p, t, tel): pass\n"),
            ("8-arg legacy", "def process(i, o, f, s, p, t, tel, sc): pass\n"),
        ];

        for (label, src) in cases {
            let script = write_temp_script(src);
            let mut kernel = DSPKernel::new();
            kernel.initialize(1, 1, 48000.0);
            let loaded = kernel.load_script(&python_home, script.to_str().unwrap());
            assert!(
                !loaded,
                "{label}: expected load to fail for non-1-arg process()"
            );
            let err = kernel.last_error().expect("last_error should be set");
            assert!(
                err.contains("must take exactly one argument"),
                "{label}: error should mention the 1-arg ctx requirement, got: {err}"
            );

            // Pin the passthrough-on-failure contract: after a rejected
            // load, the kernel must render input bit-exactly. The previous
            // bug was that the prior backend kept running, with the new
            // preset's UI driving its kernel param slots — felt like the
            // new preset worked but actually wasn't.
            let input: [f32; 4] = [0.1, -0.2, 0.7, -0.9];
            let mut output: [f32; 4] = [0.0; 4];
            let input_ptr: *const f32 = input.as_ptr();
            let output_ptr: *mut f32 = output.as_mut_ptr();
            unsafe {
                kernel.process(&input_ptr, &output_ptr, 1, 4);
            }
            assert_eq!(
                output, input,
                "{label}: rejected load must drop kernel into passthrough, got {output:?}"
            );

            std::fs::remove_file(script).ok();
        }
    }

    /// After a rejected load, kernel-side param + telemetry metadata
    /// must clear. Otherwise a subsequent successful load could blend
    /// the rejected script's stale metadata into the new run, and the
    /// audio thread would denormalize new param writes through the old
    /// (now meaningless) ranges.
    #[test]
    fn test_load_script_failure_clears_metadata_caches() {
        let (python_home, _) = match test_python_paths() {
            Some(paths) => paths,
            None => {
                eprintln!("Skipping: bundled Python runtime not found");
                return;
            }
        };

        // Step 1: load a healthy ctx-form script that declares PARAMS +
        // TELEMETRY so both metadata caches get populated.
        let healthy = write_temp_script(
            "PARAMS = {'cutoff': {'min': 20.0, 'max': 20000.0, 'default': 1000.0, 'unit': 'Hz', 'curve': 'log'}}\n\
             TELEMETRY = {'rms': {'unit': ''}}\n\
             def process(ctx):\n    pass\n",
        );
        let mut kernel = DSPKernel::new();
        kernel.initialize(1, 1, 48000.0);
        assert!(
            kernel.load_script(&python_home, healthy.to_str().unwrap()),
            "healthy script should load: {:?}",
            kernel.last_error()
        );
        assert!(
            !kernel.param_metadata_json_ptr().is_null(),
            "param metadata should be populated after a successful load"
        );
        assert!(
            !kernel.telemetry_metadata_json_ptr().is_null(),
            "telemetry metadata should be populated after a successful load"
        );

        // Step 2: load a rejected script. Caches must clear.
        let rejected = write_temp_script("def process(i, o, f, s, p, t, tel): pass\n");
        let loaded = kernel.load_script(&python_home, rejected.to_str().unwrap());
        assert!(!loaded, "7-arg script should be rejected");
        assert!(
            kernel.param_metadata_json_ptr().is_null(),
            "rejected load must clear param metadata cache"
        );
        assert!(
            kernel.telemetry_metadata_json_ptr().is_null(),
            "rejected load must clear telemetry metadata cache"
        );

        std::fs::remove_file(healthy).ok();
        std::fs::remove_file(rejected).ok();
    }

    /// Single-arg `def process(ctx):` is the only accepted shape.
    #[test]
    fn test_load_script_accepts_8_arg_sidechain_signature() {
        let (python_home, _) = match test_python_paths() {
            Some(paths) => paths,
            None => {
                eprintln!("Skipping: bundled Python runtime not found");
                return;
            }
        };
        let script = write_temp_script(
            "def process(ctx):\n    for ch in range(len(ctx.inputs)):\n        ctx.outputs[ch][:ctx.frame_count] = ctx.inputs[ch][:ctx.frame_count]\n",
        );
        let mut kernel = DSPKernel::new();
        let loaded = kernel.load_script(&python_home, script.to_str().unwrap());
        assert!(
            loaded,
            "8-arg process() should load successfully: {:?}",
            kernel.last_error()
        );
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

    /// Plan-spec perf gate from PR #305 (extended to also cover the
    /// sister presets that have the same sample-outer / channel-inner
    /// peak-detect shape — limiter, lookahead_limiter, noisegate, wah —
    /// which were caught regressing post-#305 by the same +18% mechanism
    /// the compressor did). #[ignore]'d so it doesn't run in normal CI —
    /// invoke with
    ///   cargo test --release -p conjure_dsp benchmark_perf_critical_presets \
    ///     -- --ignored --nocapture --test-threads=1
    /// Set CONJUREDSP_TONES_DIR to a path containing tone3000 .nam files
    /// (see preset_nam.cdp's referenced model); the test eprintln-skips
    /// NAM if its model can't load.
    ///
    /// Each preset: benchmark_process() is called 5 times. Each call does
    /// 1 warmup + 5 timed process() iterations and returns the MAX of the
    /// 5 timed runs (worst-case is what matters for a real-time render
    /// deadline). The outer harness then reports the MEDIAN of those 5
    /// max-times. Total: 30 process() calls per preset, reported as
    /// "median of worst-case-of-5."
    #[test]
    #[ignore = "perf benchmark; invoke with --ignored --nocapture"]
    fn benchmark_perf_critical_presets() {
        let (python_home, _) = match test_python_paths() {
            Some(paths) => paths,
            None => {
                eprintln!("Skipping: bundled Python runtime not found");
                return;
            }
        };
        let manifest_dir = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));

        if std::env::var_os("CONJUREDSP_TONES_DIR").is_none() {
            eprintln!(
                "warning: CONJUREDSP_TONES_DIR not set — preset_nam will fail to load \
                 and be skipped (still measures the other 6 presets)."
            );
        }
        let presets = [
            "preset_compressor",
            "preset_limiter",
            "preset_lookahead_limiter",
            "preset_noisegate",
            "preset_wah",
            "preset_eq3",
            "preset_nam",
        ];
        for preset in &presets {
            eprintln!(">>> benchmarking {}", preset);
            let script_path = manifest_dir.join(format!(
                "../../ConjureDSPExtension/Resources/presets/{}.cdp/process.py",
                preset
            ));
            if !script_path.exists() {
                eprintln!("Skip {}: script not found at {:?}", preset, script_path);
                continue;
            }
            let mut kernel = DSPKernel::new();
            if !kernel.load_script(&python_home, script_path.to_str().unwrap()) {
                eprintln!("Skip {}: load_script failed", preset);
                continue;
            }
            // 2 channels, 512 frames, 48kHz — a typical DAW block size.
            // initialize() takes (input_channels, _output_channels, sample_rate);
            // max_frames_to_render has its own setter.
            kernel.initialize(2, 2, 48000.0);
            kernel.set_maximum_frames_to_render(512);

            let mut times_ms: Vec<f64> = Vec::with_capacity(5);
            for _ in 0..5 {
                if let Some(t) = kernel.benchmark_process() {
                    times_ms.push(t * 1000.0);
                }
            }
            if times_ms.is_empty() {
                eprintln!("Skip {}: benchmark_process returned None", preset);
                continue;
            }
            times_ms.sort_by(|a, b| a.partial_cmp(b).unwrap());
            let median = times_ms[times_ms.len() / 2];
            let min = times_ms[0];
            let max = times_ms[times_ms.len() - 1];
            eprintln!(
                "BENCH {:25} median={:.4}ms  min={:.4}ms  max={:.4}ms  n={}",
                preset,
                median,
                min,
                max,
                times_ms.len()
            );
        }
    }

    // --- WASM integration tests ---

    fn gain_half_wasm() -> Vec<u8> {
        // Post-1cc3aff ABI: zero-arg process(), BlockInfo at offset 16,
        // module-allocated input at 1024, output at 32768.
        wat::parse_str(r#"
            (module
              (memory (export "memory") 1)
              (func (export "get_block_info_ptr") (result i32) (i32.const 16))
              (func (export "get_input_ptr")      (result i32) (i32.const 1024))
              (func (export "get_output_ptr")     (result i32) (i32.const 32768))
              (func (export "process")
                (local $i i32)
                (local $total i32)
                (local.set $total
                  (i32.mul
                    (i32.load (i32.const 16))
                    (i32.load (i32.const 20))))
                (block $break
                  (loop $loop
                    (br_if $break (i32.ge_u (local.get $i) (local.get $total)))
                    (f32.store
                      (i32.add (i32.const 32768) (i32.mul (local.get $i) (i32.const 4)))
                      (f32.mul
                        (f32.load (i32.add (i32.const 1024) (i32.mul (local.get $i) (i32.const 4))))
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
              (func (export "get_block_info_ptr") (result i32) (i32.const 16))
              (func (export "get_input_ptr")      (result i32) (i32.const 1024))
              (func (export "get_output_ptr")     (result i32) (i32.const 32768))
              (func (export "process")
                (local $i i32)
                (local $total i32)
                (local.set $total
                  (i32.mul
                    (i32.load (i32.const 16))
                    (i32.load (i32.const 20))))
                (block $break
                  (loop $loop
                    (br_if $break (i32.ge_u (local.get $i) (local.get $total)))
                    (f32.store
                      (i32.add (i32.const 32768) (i32.mul (local.get $i) (i32.const 4)))
                      (f32.load (i32.add (i32.const 1024) (i32.mul (local.get $i) (i32.const 4))))
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

        // Drive enough chunks through to complete the swap fade envelope; the
        // audio thread performs the swap at end-of-buffer so several callbacks
        // are needed before the new backend is producing steady-state output.
        let chunk_input = vec![0.7f32; 256];
        let mut chunk_output = vec![0.0f32; 256];
        for _ in 0..6 {
            chunk_output.fill(0.0);
            let cip: *const f32 = chunk_input.as_ptr();
            let cop: *mut f32 = chunk_output.as_mut_ptr();
            unsafe { kernel.process(&cip, &cop, 1, 256); }
        }
        let tail = &chunk_output[chunk_output.len() - 4..];
        assert_eq!(tail, &[0.7, 0.7, 0.7, 0.7]);
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

        // Drive enough chunks for the swap fade to complete; check the tail.
        let chunk_input = vec![1.0f32; 256];
        let mut chunk_output = vec![0.0f32; 256];
        for _ in 0..6 {
            chunk_output.fill(0.0);
            let cip: *const f32 = chunk_input.as_ptr();
            let cop: *mut f32 = chunk_output.as_mut_ptr();
            unsafe { kernel.process(&cip, &cop, 1, 256); }
        }
        let tail = &chunk_output[chunk_output.len() - 4..];
        // gain_half_wasm applies 0.5x
        assert_eq!(tail, &[0.5, 0.5, 0.5, 0.5]);
    }

    // --- Safety limiter tests ---

    fn gain_10x_wasm() -> Vec<u8> {
        wat::parse_str(r#"
            (module
              (memory (export "memory") 1)
              (func (export "get_block_info_ptr") (result i32) (i32.const 16))
              (func (export "get_input_ptr")      (result i32) (i32.const 1024))
              (func (export "get_output_ptr")     (result i32) (i32.const 32768))
              (func (export "process")
                (local $i i32)
                (local $total i32)
                (local.set $total
                  (i32.mul
                    (i32.load (i32.const 16))
                    (i32.load (i32.const 20))))
                (block $break
                  (loop $loop
                    (br_if $break (i32.ge_u (local.get $i) (local.get $total)))
                    (f32.store
                      (i32.add (i32.const 32768) (i32.mul (local.get $i) (i32.const 4)))
                      (f32.mul
                        (f32.load (i32.add (i32.const 1024) (i32.mul (local.get $i) (i32.const 4))))
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
            "import numpy as np\ndef process(ctx):\n    for ch in range(len(ctx.inputs)):\n        ctx.outputs[ch][:ctx.frame_count] = ctx.inputs[ch][:ctx.frame_count] * 10.0\n",
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

        // Drive enough chunks for the swap fade to complete; check the tail.
        let chunk_input = vec![1.0f32; 256];
        let mut chunk_output = vec![0.0f32; 256];
        for _ in 0..6 {
            chunk_output.fill(0.0);
            let cip: *const f32 = chunk_input.as_ptr();
            let cop: *mut f32 = chunk_output.as_mut_ptr();
            unsafe { kernel.process(&cip, &cop, 1, 256); }
        }
        let tail = &chunk_output[chunk_output.len() - 4..];
        // process.py is unity gain
        assert_eq!(tail, &[1.0, 1.0, 1.0, 1.0]);
    }

    /// Regression test for the preset-switch pop. Loads a backend that emits a
    /// constant 0.5, swaps to a backend that emits silence, and verifies that
    /// the transition is smooth — no single-sample step exceeds a small
    /// threshold and there is a visible fade region in the output.
    #[test]
    fn test_preset_swap_declick_envelope() {
        // Backend A: outputs the input scaled by 0.5 (we'll feed it constant 1.0
        // to get a steady 0.5 output).
        let wasm_a = gain_half_wasm();

        // Backend B: outputs silence regardless of input.
        let wasm_b = wat::parse_str(r#"
            (module
              (memory (export "memory") 1)
              (func (export "get_block_info_ptr") (result i32) (i32.const 16))
              (func (export "get_input_ptr")      (result i32) (i32.const 1024))
              (func (export "get_output_ptr")     (result i32) (i32.const 32768))
              (func (export "process")
                (local $i i32)
                (local $total i32)
                (local.set $total
                  (i32.mul
                    (i32.load (i32.const 16))
                    (i32.load (i32.const 20))))
                (block $break
                  (loop $loop
                    (br_if $break (i32.ge_u (local.get $i) (local.get $total)))
                    (f32.store
                      (i32.add (i32.const 32768) (i32.mul (local.get $i) (i32.const 4)))
                      (f32.const 0.0)
                    )
                    (local.set $i (i32.add (local.get $i) (i32.const 1)))
                    (br $loop)
                  )
                )
              )
            )
        "#).expect("Failed to parse silence WAT");

        let mut kernel = DSPKernel::new();
        assert!(kernel.load_wasm(&wasm_a));
        kernel.initialize(1, 1, 44100.0);

        // Process a chunk with the original backend so it's producing 0.5
        // before the swap is requested.
        let input = vec![1.0f32; 64];
        let mut warm = vec![0.0f32; 64];
        unsafe {
            let ip: *const f32 = input.as_ptr();
            let op: *mut f32 = warm.as_mut_ptr();
            kernel.process(&ip, &op, 1, 64);
        }
        assert!(warm.iter().all(|&v| (v - 0.5).abs() < 1e-6),
                "warm-up should produce constant 0.5");

        // Stage the silent backend — this arms the fade-out.
        assert!(kernel.load_wasm(&wasm_b));

        // Capture the audio across the entire swap window. Process in 64-frame
        // chunks (mirroring a small DAW callback) and concatenate.
        const CHUNK: u32 = 64;
        // 32 * 64 = 2048 samples ≫ 1320-sample fade window (15 ms × 2 @ 44.1 kHz).
        const NUM_CHUNKS: usize = 32;
        let mut captured: Vec<f32> = Vec::with_capacity(CHUNK as usize * NUM_CHUNKS);
        for _ in 0..NUM_CHUNKS {
            let mut out = vec![0.0f32; CHUNK as usize];
            unsafe {
                let ip: *const f32 = input.as_ptr();
                let op: *mut f32 = out.as_mut_ptr();
                kernel.process(&ip, &op, 1, CHUNK);
            }
            captured.extend_from_slice(&out);
        }

        // No single-sample step in the output should exceed a small threshold.
        // Without declick, the swap would produce a 0.5-sample step (from 0.5
        // to 0.0 in one frame). The fade brings the per-sample delta well below
        // 0.02 across all transitions.
        let mut max_delta = 0.0f32;
        for w in captured.windows(2) {
            let d = (w[1] - w[0]).abs();
            if d > max_delta {
                max_delta = d;
            }
        }
        assert!(
            max_delta < 0.02,
            "step discontinuity {} exceeds declick threshold (0.02)",
            max_delta
        );

        // The first sample should still be at the old backend's level (0.5),
        // and the final samples should reach the new backend's level (0.0).
        assert!((captured[0] - 0.5).abs() < 1e-3,
                "first sample should be ~0.5 (old backend), got {}", captured[0]);
        assert!(captured[captured.len() - 1].abs() < 1e-3,
                "last sample should be ~0.0 (new backend), got {}",
                captured[captured.len() - 1]);

        // There should be a visible monotonic-ish fade region: the first half
        // should average noticeably higher than the second half.
        let mid = captured.len() / 2;
        let first_half_avg: f32 = captured[..mid].iter().sum::<f32>() / mid as f32;
        let second_half_avg: f32 = captured[mid..].iter().sum::<f32>() / (captured.len() - mid) as f32;
        assert!(first_half_avg > second_half_avg + 0.05,
                "expected fade-down: first_half={}, second_half={}",
                first_half_avg, second_half_avg);
    }

    /// Regression test for PR #215 review: rapidly switching presets during
    /// the FADE_IN half of a previous swap must preserve gain continuity.
    /// Before the fix, `stage_backend_for_swap` reset `swap_fade_remaining`
    /// to full length and flipped to FADE_OUT, jumping the envelope gain
    /// from its current mid-fade-in value straight to 1.0 — an audible click.
    ///
    /// This test drives A → B → C in quick succession: after only a few
    /// callbacks of fade-in on (A → B), it loads C. The captured output must
    /// still have no step discontinuity anywhere.
    #[test]
    fn test_preset_swap_interrupted_fade_in_declicks() {
        // Build three trivial WASM backends with distinct constant outputs.
        let silence_wat = |c: f32| {
            let bits = c.to_bits();
            format!(
                r#"
                (module
                  (memory (export "memory") 1)
                  (func (export "get_block_info_ptr") (result i32) (i32.const 16))
                  (func (export "get_input_ptr")      (result i32) (i32.const 1024))
                  (func (export "get_output_ptr")     (result i32) (i32.const 32768))
                  (func (export "process")
                    (local $i i32)
                    (local $total i32)
                    (local.set $total
                      (i32.mul
                        (i32.load (i32.const 16))
                        (i32.load (i32.const 20))))
                    (block $break
                      (loop $loop
                        (br_if $break (i32.ge_u (local.get $i) (local.get $total)))
                        (f32.store
                          (i32.add (i32.const 32768) (i32.mul (local.get $i) (i32.const 4)))
                          (f32.const {c})
                        )
                        (local.set $i (i32.add (local.get $i) (i32.const 1)))
                        (br $loop)
                      )
                    )
                  )
                )
                "#,
                c = f32::from_bits(bits),
            )
        };

        let wasm_a = gain_half_wasm(); // outputs input * 0.5
        let wasm_b = wat::parse_str(&silence_wat(0.25)).unwrap();
        let wasm_c = wat::parse_str(&silence_wat(0.0)).unwrap();

        let mut kernel = DSPKernel::new();
        assert!(kernel.load_wasm(&wasm_a));
        kernel.initialize(1, 1, 44100.0);

        // Warm up A so it's producing steady 0.5.
        let input = vec![1.0f32; 64];
        let mut warm = vec![0.0f32; 64];
        unsafe {
            let ip: *const f32 = input.as_ptr();
            let op: *mut f32 = warm.as_mut_ptr();
            kernel.process(&ip, &op, 1, 64);
        }
        assert!(warm.iter().all(|&v| (v - 0.5).abs() < 1e-6));

        // Stage B. Fade length at 44.1 kHz is ~661 samples (15 ms). Run a
        // fade-out + just part of fade-in so we catch it mid-fade-in.
        assert!(kernel.load_wasm(&wasm_b));
        const CHUNK: u32 = 64;
        let mut captured: Vec<f32> = Vec::new();
        // 12 * 64 = 768 samples — 661 fade-out completes around chunk 11,
        // so by chunk 12 we're a few samples into FADE_IN but nowhere near
        // its 661-sample completion.
        for _ in 0..12 {
            let mut out = vec![0.0f32; CHUNK as usize];
            unsafe {
                let ip: *const f32 = input.as_ptr();
                let op: *mut f32 = out.as_mut_ptr();
                kernel.process(&ip, &op, 1, CHUNK);
            }
            captured.extend_from_slice(&out);
        }

        // Now stage C while we're *during* the FADE_IN toward B. Verify the
        // audio thread is in fact in FADE_IN by peeking the phase.
        let phase_before_interrupt = kernel.swap_phase.load(Ordering::Acquire);
        assert_eq!(
            phase_before_interrupt, SWAP_PHASE_FADE_IN,
            "precondition: should be mid fade-in after 12 chunks (768 samples, \
             fade-out was 661) but phase = {}",
            phase_before_interrupt
        );
        assert!(kernel.load_wasm(&wasm_c));

        // Continue processing long enough for A → B fade-out (interrupted),
        // B fade-out, and C fade-in to all complete.
        for _ in 0..32 {
            let mut out = vec![0.0f32; CHUNK as usize];
            unsafe {
                let ip: *const f32 = input.as_ptr();
                let op: *mut f32 = out.as_mut_ptr();
                kernel.process(&ip, &op, 1, CHUNK);
            }
            captured.extend_from_slice(&out);
        }

        // No single-sample step in the output should exceed the declick
        // threshold. Before the fix, we'd see a large step (up to ~0.5 worst
        // case) right at the interrupted-fade-in transition.
        let mut max_delta = 0.0f32;
        let mut max_delta_idx = 0usize;
        for (i, w) in captured.windows(2).enumerate() {
            let d = (w[1] - w[0]).abs();
            if d > max_delta {
                max_delta = d;
                max_delta_idx = i;
            }
        }
        assert!(
            max_delta < 0.02,
            "step discontinuity {} at sample {} exceeds declick threshold \
             (0.02) — interrupted fade-in caused a click",
            max_delta, max_delta_idx
        );

        // Final value should settle at C's output (0.0).
        assert!(
            captured[captured.len() - 1].abs() < 1e-3,
            "should settle at C's output (0.0), got {}",
            captured[captured.len() - 1]
        );
    }

    /// Reproduces the user-reported bug (Asana 1214132137985530): the OLD
    /// backend keeps rendering with the NEW preset's parameter values during
    /// the load window, producing a click that the per-swap fade envelope
    /// alone cannot absorb. `begin_preset_transition` / `end_preset_transition`
    /// must hold output muted across the entire window — including direct
    /// `set_parameter` writes to the live backend before the new backend is
    /// staged — so the user hears silence, not a click.
    ///
    /// We don't need backend A to actually read the parameter values for
    /// this test: the envelope-as-mute behavior is what we're verifying,
    /// and a backend that produces continuous non-zero output through the
    /// transition is a sufficient witness to whether muting works.
    #[test]
    fn test_preset_transition_mutes_through_param_changes() {
        let wasm_a = gain_half_wasm();
        let wasm_b = gain_half_wasm();

        let mut kernel = DSPKernel::new();
        assert!(kernel.load_wasm(&wasm_a));
        kernel.initialize(1, 1, 44100.0);

        // Initialize the gain param to 0.5 and warm up so output is steady.
        kernel.set_parameter(0, 0.5);
        let input = vec![1.0f32; 64];
        let mut warm = vec![0.0f32; 64];
        unsafe {
            let ip: *const f32 = input.as_ptr();
            let op: *mut f32 = warm.as_mut_ptr();
            kernel.process(&ip, &op, 1, 64);
        }

        // Begin transition — Swift signals the audio thread to mute output
        // across the load window.
        kernel.begin_preset_transition();

        // Now do exactly what `selectPreset` → `applyManifestParams` does:
        // slam parameter values that don't match the OLD backend's continuous
        // state. In production these are the new preset's defaults written
        // directly into kernel.params[] before the new backend is staged.
        kernel.set_parameter(0, 1.0);
        kernel.set_parameter(1, 0.123);
        kernel.set_parameter(2, 0.987);

        // Process for several callbacks under the parameter mismatch — these
        // must all be silenced by the transition envelope.
        const CHUNK: u32 = 64;
        let mut captured: Vec<f32> = Vec::new();
        // 50 chunks * 64 = 3200 samples ≫ 661-sample fade-out. By the end of
        // this loop the envelope is well past FADE_OUT into the silent hold.
        for _ in 0..50 {
            let mut out = vec![0.0f32; CHUNK as usize];
            unsafe {
                let ip: *const f32 = input.as_ptr();
                let op: *mut f32 = out.as_mut_ptr();
                kernel.process(&ip, &op, 1, CHUNK);
            }
            captured.extend_from_slice(&out);
        }

        // Stage backend B (simulating compileAndRun → load_wasm). The audio
        // thread will swap it in at the next callback's FADE_OUT-completion
        // site — but stay muted because transition_active is set.
        assert!(kernel.load_wasm(&wasm_b));
        for _ in 0..50 {
            let mut out = vec![0.0f32; CHUNK as usize];
            unsafe {
                let ip: *const f32 = input.as_ptr();
                let op: *mut f32 = out.as_mut_ptr();
                kernel.process(&ip, &op, 1, CHUNK);
            }
            captured.extend_from_slice(&out);
        }

        // End transition — audio thread ramps back up via FADE_IN.
        kernel.end_preset_transition();
        for _ in 0..50 {
            let mut out = vec![0.0f32; CHUNK as usize];
            unsafe {
                let ip: *const f32 = input.as_ptr();
                let op: *mut f32 = out.as_mut_ptr();
                kernel.process(&ip, &op, 1, CHUNK);
            }
            captured.extend_from_slice(&out);
        }

        // No single-sample step in the entire captured window may exceed the
        // declick threshold. The bug this protects against produces ~0.5
        // sample-to-sample steps when the OLD backend processes a buffer
        // with brand-new parameter values mid-load.
        let mut max_delta = 0.0f32;
        let mut max_delta_idx = 0usize;
        for (i, w) in captured.windows(2).enumerate() {
            let d = (w[1] - w[0]).abs();
            if d > max_delta {
                max_delta = d;
                max_delta_idx = i;
            }
        }
        assert!(
            max_delta < 0.02,
            "step discontinuity {} at sample {} exceeds declick threshold (0.02)",
            max_delta, max_delta_idx
        );

        // After the transition ends and the FADE_IN completes, the kernel
        // returns to IDLE and processes backend B at full volume.
        assert_eq!(kernel.swap_phase(), SWAP_PHASE_IDLE,
                   "kernel should return to IDLE after end_preset_transition + fade-in");
        assert!(!kernel.transition_active(),
                "transition should be inactive at end of test");

        // Verify there's a sustained silent region in the middle of the
        // capture — the held-mute window. Capture timeline (44.1 kHz, 64-frame
        // chunks, 15 ms fade): samples 0–661 are FADE_OUT, 661–3200 are
        // mute-hold during pre-load_wasm, 3200–6400 are mute-hold during
        // post-swap. End-of-transition fires at sample 6400 and FADE_IN
        // takes another 661 samples. So [3000..6000] is strictly inside the
        // held-mute window for both halves of the load.
        let mute_window = &captured[3000..6000.min(captured.len())];
        let mute_peak = mute_window.iter().fold(0.0f32, |a, &v| a.max(v.abs()));
        assert!(mute_peak < 0.01,
                "expected sustained silence during hold window, got peak {}",
                mute_peak);
    }

    /// Regression test for Sentry Seer review on PR #283: rapid Rust factory
    /// preset switches each spawn a `Task` that calls `end_preset_transition`
    /// when its compile finishes. With a boolean flag, Task #1's `end` would
    /// clear the mute while Task #2 is still compiling — clicking the audio.
    /// With the refcount, each `begin` increments and each `end` decrements;
    /// audio only unmutes when the depth returns to zero.
    #[test]
    fn test_preset_transition_overlapping_begins_only_unmute_after_all_ends() {
        let wasm = gain_half_wasm();
        let mut kernel = DSPKernel::new();
        assert!(kernel.load_wasm(&wasm));
        kernel.initialize(1, 1, 44100.0);

        // Warm up.
        let input = vec![1.0f32; 64];
        let mut warm = vec![0.0f32; 64];
        unsafe {
            let ip: *const f32 = input.as_ptr();
            let op: *mut f32 = warm.as_mut_ptr();
            kernel.process(&ip, &op, 1, 64);
        }

        // Two overlapping transitions. begin/begin then end/end.
        kernel.begin_preset_transition();
        kernel.begin_preset_transition();
        assert!(kernel.transition_active(), "depth should be 2 after two begins");

        // First end (Task #1 finishing) — depth drops to 1, NOT 0. Audio
        // must stay muted because Task #2 is still nominally in flight.
        kernel.end_preset_transition();
        assert!(kernel.transition_active(),
                "depth should still be 1 after first end — second transition still in flight");

        // Run several callbacks. Output must remain silent (envelope clamps
        // gain to 0 because the audio thread is still parked in FADE_OUT).
        const CHUNK: u32 = 64;
        let mut captured: Vec<f32> = Vec::new();
        for _ in 0..32 {
            let mut out = vec![0.0f32; CHUNK as usize];
            unsafe {
                let ip: *const f32 = input.as_ptr();
                let op: *mut f32 = out.as_mut_ptr();
                kernel.process(&ip, &op, 1, CHUNK);
            }
            captured.extend_from_slice(&out);
        }
        // Skip the 661-sample fade-out region — those samples are legitimately
        // ramping. After the fade, output must be silent.
        let post_fade = &captured[700..];
        let post_fade_peak = post_fade.iter().fold(0.0f32, |a, &v| a.max(v.abs()));
        assert!(post_fade_peak < 0.01,
                "audio must remain silent between first and second end (got peak {})",
                post_fade_peak);

        // Second end (Task #2 finishing) — depth drops to 0, audio ramps up.
        kernel.end_preset_transition();
        assert!(!kernel.transition_active(),
                "depth should be 0 after both ends");

        // Pump enough callbacks to complete FADE_IN.
        for _ in 0..32 {
            let mut out = vec![0.0f32; CHUNK as usize];
            unsafe {
                let ip: *const f32 = input.as_ptr();
                let op: *mut f32 = out.as_mut_ptr();
                kernel.process(&ip, &op, 1, CHUNK);
            }
        }
        assert_eq!(kernel.swap_phase(), SWAP_PHASE_IDLE,
                   "kernel should return to IDLE once depth is 0 + fade-in completes");
    }

    /// Regression test for Sentry Seer review on PR #283: during a held
    /// preset transition (parked in FADE_OUT / rem=0 across many callbacks),
    /// the FADE_OUT-completion site was calling `perform_swap_locked` every
    /// callback. After the first swap installs NEW into live and parks OLD
    /// in pending, each subsequent call would re-swap them, leaving a
    /// non-deterministic backend live when the transition ended. Verify the
    /// `pending_backend_fresh` gate now installs the new backend exactly
    /// once and leaves it there.
    #[test]
    fn test_preset_transition_swap_runs_at_most_once_during_hold() {
        // Backend A produces 0.5; backend B produces 0.0. After the swap
        // completes, the LIVE slot must be B regardless of how many
        // callbacks elapse during the hold.
        let wasm_a = gain_half_wasm();
        let wasm_b = wat::parse_str(r#"
            (module
              (memory (export "memory") 1)
              (func (export "get_block_info_ptr") (result i32) (i32.const 16))
              (func (export "get_input_ptr")      (result i32) (i32.const 1024))
              (func (export "get_output_ptr")     (result i32) (i32.const 32768))
              (func (export "process")
                (local $i i32)
                (local $total i32)
                (local.set $total
                  (i32.mul
                    (i32.load (i32.const 16))
                    (i32.load (i32.const 20))))
                (block $break
                  (loop $loop
                    (br_if $break (i32.ge_u (local.get $i) (local.get $total)))
                    (f32.store
                      (i32.add (i32.const 32768) (i32.mul (local.get $i) (i32.const 4)))
                      (f32.const 0.0)
                    )
                    (local.set $i (i32.add (local.get $i) (i32.const 1)))
                    (br $loop)
                  )
                )
              )
            )
        "#).expect("Failed to parse silence WAT");

        let mut kernel = DSPKernel::new();
        assert!(kernel.load_wasm(&wasm_a));
        kernel.initialize(1, 1, 44100.0);

        // Warm up so A is producing 0.5 steady state.
        let input = vec![1.0f32; 64];
        let mut warm = vec![0.0f32; 64];
        unsafe {
            let ip: *const f32 = input.as_ptr();
            let op: *mut f32 = warm.as_mut_ptr();
            kernel.process(&ip, &op, 1, 64);
        }

        kernel.begin_preset_transition();
        // Stage B during the hold.
        assert!(kernel.load_wasm(&wasm_b));

        // Process a LARGE number of callbacks while the transition is held.
        // Pre-fix this would oscillate live ↔ pending on every callback past
        // the first FADE_OUT-completion (≥ chunk 11 at 44.1 kHz / 64 frames).
        const CHUNK: u32 = 64;
        for _ in 0..100 {
            let mut out = vec![0.0f32; CHUNK as usize];
            unsafe {
                let ip: *const f32 = input.as_ptr();
                let op: *mut f32 = out.as_mut_ptr();
                kernel.process(&ip, &op, 1, CHUNK);
            }
        }

        // End the transition and process enough callbacks to drain FADE_IN.
        kernel.end_preset_transition();
        let mut final_out = vec![0.0f32; CHUNK as usize];
        for _ in 0..32 {
            unsafe {
                let ip: *const f32 = input.as_ptr();
                let op: *mut f32 = final_out.as_mut_ptr();
                kernel.process(&ip, &op, 1, CHUNK);
            }
        }
        assert_eq!(kernel.swap_phase(), SWAP_PHASE_IDLE);

        // The live backend must be B (silence), not A (0.5). Pre-fix, an
        // odd number of callbacks during the hold would leave A live again.
        let final_peak = final_out.iter().fold(0.0f32, |a, &v| a.max(v.abs()));
        assert!(final_peak < 1e-3,
                "live backend after transition must be B (silence), got peak {} \
                 (looks like A oscillated back into live)", final_peak);
    }

    /// Regression test for Sentry Seer review on PR #283: if `perform_swap_locked`
    /// fails to acquire the `pending_backend` lock (e.g. main thread is mid
    /// `inject_nam_slot`), the fresh-stage flag must NOT stay cleared — otherwise
    /// the staged backend is stranded forever. The retry path restores the flag
    /// so the next callback re-attempts the swap.
    #[test]
    fn test_preset_transition_swap_retries_under_contention() {
        let wasm_a = gain_half_wasm();
        let wasm_b = gain_half_wasm();
        let mut kernel = DSPKernel::new();
        assert!(kernel.load_wasm(&wasm_a));
        kernel.initialize(1, 1, 44100.0);

        // Warm up.
        let input = vec![1.0f32; 64];
        let mut warm = vec![0.0f32; 64];
        unsafe {
            let ip: *const f32 = input.as_ptr();
            let op: *mut f32 = warm.as_mut_ptr();
            kernel.process(&ip, &op, 1, 64);
        }

        // Stage B. This sets pending_backend_fresh = true.
        assert!(kernel.load_wasm(&wasm_b));
        // Sanity: fresh flag is set.
        assert!(kernel.pending_backend_fresh.load(Ordering::Acquire));

        // Simulate `inject_nam_slot` holding `pending_backend.lock()` across
        // the next several render callbacks — this is exactly the contention
        // case that previously stranded the staged backend. Raw-pointer
        // escape so the same test thread can both hold the lock AND drive
        // `process` (which takes `&mut self` but only touches disjoint
        // fields). In production these run on different threads.
        let kernel_ptr: *mut DSPKernel = &mut kernel;
        const CHUNK: u32 = 64;
        {
            let _pending_guard = unsafe { (*kernel_ptr).pending_backend.lock().unwrap() };

            // Run enough callbacks to complete FADE_OUT and reach the swap point.
            // Pre-fix: the FADE_OUT-completion site would consume the fresh flag,
            // call perform_swap_locked, which bails on contention, leaving the
            // flag false — staged backend stranded.
            for _ in 0..16 {
                let mut out = vec![0.0f32; CHUNK as usize];
                unsafe {
                    let ip: *const f32 = input.as_ptr();
                    let op: *mut f32 = out.as_mut_ptr();
                    (*kernel_ptr).process(&ip, &op, 1, CHUNK);
                }
            }

            // The fresh flag must STILL be set — every contended attempt should
            // restore it so the swap can retry once the lock frees.
            assert!(unsafe { (*kernel_ptr).pending_backend_fresh.load(Ordering::Acquire) },
                    "fresh flag must be restored when perform_swap_locked is contended");
        }

        // Run more callbacks (lock now released); the swap goes through.
        for _ in 0..32 {
            let mut out = vec![0.0f32; CHUNK as usize];
            unsafe {
                let ip: *const f32 = input.as_ptr();
                let op: *mut f32 = out.as_mut_ptr();
                kernel.process(&ip, &op, 1, CHUNK);
            }
        }

        // Fresh flag is now consumed (swap actually happened) and we returned
        // to IDLE.
        assert!(!kernel.pending_backend_fresh.load(Ordering::Acquire),
                "fresh flag should be cleared after the contended swap retries and succeeds");
        assert_eq!(kernel.swap_phase(), SWAP_PHASE_IDLE);
    }

    /// Regression test for Sentry Seer review on PR #283: `benchmark_process`
    /// must not time out when called inside a held preset transition. Pre-fix,
    /// the poll waited for `swap_phase == IDLE`, which stays in FADE_OUT for
    /// the entire transition window — so every preset load incurred a 100 ms
    /// stall on the main thread and lost the benchmark result. Post-fix, the
    /// poll waits for `pending_backend_fresh` to clear (which happens as soon
    /// as the swap lands, regardless of whether the envelope advances to
    /// FADE_IN or stays parked).
    #[test]
    fn test_benchmark_process_during_held_transition_does_not_time_out() {
        let wasm = gain_half_wasm();
        let mut kernel = DSPKernel::new();
        assert!(kernel.load_wasm(&wasm));
        kernel.initialize(1, 1, 44100.0);

        // Warm up so a first-load fast path didn't apply (we need the
        // staging path for the next load to actually exercise the swap).
        let input = vec![1.0f32; 64];
        let mut warm = vec![0.0f32; 64];
        unsafe {
            let ip: *const f32 = input.as_ptr();
            let op: *mut f32 = warm.as_mut_ptr();
            kernel.process(&ip, &op, 1, 64);
        }

        // Begin a transition (depth=1) — audio thread will park in FADE_OUT
        // and never reach IDLE until end is called.
        kernel.begin_preset_transition();

        // Stage a new backend (mirrors what `compileAndRun` does before
        // benchmarking).
        let wasm_b = gain_half_wasm();
        assert!(kernel.load_wasm(&wasm_b));

        // Drive enough callbacks to let the audio thread complete the swap.
        // FADE_OUT is 661 samples at 44.1 kHz; 16 × 64 = 1024 samples.
        const CHUNK: u32 = 64;
        for _ in 0..16 {
            let mut out = vec![0.0f32; CHUNK as usize];
            unsafe {
                let ip: *const f32 = input.as_ptr();
                let op: *mut f32 = out.as_mut_ptr();
                kernel.process(&ip, &op, 1, CHUNK);
            }
        }
        // Sanity: phase is held in FADE_OUT, but the swap landed
        // (pending_backend_fresh was cleared by perform_swap_locked).
        assert_eq!(kernel.swap_phase(), SWAP_PHASE_FADE_OUT,
                   "transition should hold us in FADE_OUT");
        assert!(!kernel.pending_backend_fresh.load(Ordering::Acquire),
                "swap should have completed during the held transition");

        // Benchmark should run quickly (no 100 ms timeout) and return Some.
        let start = std::time::Instant::now();
        let result = kernel.benchmark_process();
        let elapsed = start.elapsed();

        assert!(result.is_some(),
                "benchmark must succeed during a held transition (got None)");
        assert!(elapsed < std::time::Duration::from_millis(50),
                "benchmark should not have polled near the 100 ms timeout (took {:?})",
                elapsed);

        // Cleanup.
        kernel.end_preset_transition();
    }

    /// Saturating end: a stray `end_preset_transition` with no matching
    /// `begin` must not drive the depth negative.
    #[test]
    fn test_preset_transition_unpaired_end_saturates_at_zero() {
        let kernel = DSPKernel::new();
        assert!(!kernel.transition_active());

        kernel.end_preset_transition();
        kernel.end_preset_transition();
        assert!(!kernel.transition_active(),
                "unpaired ends must not make transition_active true on the next begin");

        // After the saturation, a single begin/end pair should still work.
        kernel.begin_preset_transition();
        assert!(kernel.transition_active());
        kernel.end_preset_transition();
        assert!(!kernel.transition_active());
    }

    /// Watchdog regression: if Swift sets transition_active but never clears
    /// it (buggy caller, crashed mid-load), the kernel must auto-recover so
    /// the plugin doesn't sit silent forever.
    #[test]
    fn test_preset_transition_watchdog_recovers() {
        let wasm = gain_half_wasm();
        let mut kernel = DSPKernel::new();
        assert!(kernel.load_wasm(&wasm));
        kernel.initialize(1, 1, 44100.0);

        // Warm up at full volume.
        let input = vec![1.0f32; 64];
        let mut warm = vec![0.0f32; 64];
        unsafe {
            let ip: *const f32 = input.as_ptr();
            let op: *mut f32 = warm.as_mut_ptr();
            kernel.process(&ip, &op, 1, 64);
        }

        // Begin transition; never call end. Process more than
        // TRANSITION_WATCHDOG_SECONDS (2.0 s) of audio at 44.1 kHz —
        // well past the 88200-sample threshold.
        kernel.begin_preset_transition();
        assert!(kernel.transition_active());

        const CHUNK: u32 = 1024;
        let chunks_for_3_seconds = (3.0 * 44100.0 / CHUNK as f32).ceil() as usize;
        let mut input = vec![1.0f32; CHUNK as usize];
        // Use varying input so output isn't accidentally zero.
        for (i, v) in input.iter_mut().enumerate() {
            *v = ((i % 17) as f32 / 17.0) - 0.5;
        }
        let mut last_out = vec![0.0f32; CHUNK as usize];
        for _ in 0..chunks_for_3_seconds {
            unsafe {
                let ip: *const f32 = input.as_ptr();
                let op: *mut f32 = last_out.as_mut_ptr();
                kernel.process(&ip, &op, 1, CHUNK);
            }
        }

        // Watchdog must have fired and cleared the flag.
        assert!(!kernel.transition_active(),
                "watchdog should have force-cleared transition_active after >2s");

        // After clearing, the audio thread should ramp back up. Process
        // enough to complete FADE_IN and reach IDLE.
        let mut more_chunks = vec![0.0f32; CHUNK as usize];
        for _ in 0..32 {
            unsafe {
                let ip: *const f32 = input.as_ptr();
                let op: *mut f32 = more_chunks.as_mut_ptr();
                kernel.process(&ip, &op, 1, CHUNK);
            }
        }
        assert_eq!(kernel.swap_phase(), SWAP_PHASE_IDLE,
                   "kernel should return to IDLE after watchdog recovery + fade-in");
    }

    /// Verify the transition envelope behaves correctly at 96 kHz with a
    /// 1024-sample render buffer — the Logic Pro high-sample-rate scenario
    /// where the 15 ms fade window (1440 samples) doesn't fit in a single
    /// callback. Without proper buffer-edge handling, the envelope would
    /// produce a step at each buffer boundary.
    #[test]
    fn test_preset_transition_at_96khz_large_buffer() {
        let wasm_a = gain_half_wasm();
        let wasm_b = gain_half_wasm();

        let mut kernel = DSPKernel::new();
        assert!(kernel.load_wasm(&wasm_a));
        kernel.set_maximum_frames_to_render(1024);
        kernel.initialize(1, 1, 96_000.0);

        let input = vec![1.0f32; 1024];
        // Warm up.
        let mut warm = vec![0.0f32; 1024];
        unsafe {
            let ip: *const f32 = input.as_ptr();
            let op: *mut f32 = warm.as_mut_ptr();
            kernel.process(&ip, &op, 1, 1024);
        }

        // Run the full begin → swap → end cycle at 96 kHz / 1024-sample buffer.
        kernel.begin_preset_transition();
        kernel.set_parameter(0, 0.99);
        kernel.set_parameter(3, 0.42);

        const CHUNK: u32 = 1024;
        let mut captured: Vec<f32> = Vec::new();
        // 8 chunks = 8192 samples = ~85 ms. 15 ms fade-out (1440 samples)
        // fits in the first ~1.5 buffers; the rest are held silent.
        for _ in 0..8 {
            let mut out = vec![0.0f32; CHUNK as usize];
            unsafe {
                let ip: *const f32 = input.as_ptr();
                let op: *mut f32 = out.as_mut_ptr();
                kernel.process(&ip, &op, 1, CHUNK);
            }
            captured.extend_from_slice(&out);
        }

        // Stage B and continue muted.
        assert!(kernel.load_wasm(&wasm_b));
        for _ in 0..4 {
            let mut out = vec![0.0f32; CHUNK as usize];
            unsafe {
                let ip: *const f32 = input.as_ptr();
                let op: *mut f32 = out.as_mut_ptr();
                kernel.process(&ip, &op, 1, CHUNK);
            }
            captured.extend_from_slice(&out);
        }

        // End and ramp back up.
        kernel.end_preset_transition();
        for _ in 0..8 {
            let mut out = vec![0.0f32; CHUNK as usize];
            unsafe {
                let ip: *const f32 = input.as_ptr();
                let op: *mut f32 = out.as_mut_ptr();
                kernel.process(&ip, &op, 1, CHUNK);
            }
            captured.extend_from_slice(&out);
        }

        // Per-sample step must stay below the declick threshold across
        // every buffer boundary, including at the FADE_OUT/HOLD junction
        // and the HOLD/FADE_IN junction.
        let mut max_delta = 0.0f32;
        let mut max_delta_idx = 0usize;
        for (i, w) in captured.windows(2).enumerate() {
            let d = (w[1] - w[0]).abs();
            if d > max_delta {
                max_delta = d;
                max_delta_idx = i;
            }
        }
        assert!(
            max_delta < 0.02,
            "step discontinuity {} at sample {} exceeds declick threshold \
             at 96 kHz / 1024-frame buffer",
            max_delta, max_delta_idx
        );

        assert_eq!(kernel.swap_phase(), SWAP_PHASE_IDLE);
    }

    /// Back-to-back transitions (user clicking presets faster than the
    /// envelope can complete a fade-in) must not click. Each `begin` re-arms
    /// FADE_OUT from whatever phase the envelope was in (including a
    /// just-started FADE_IN); each `end` releases the hold.
    #[test]
    fn test_preset_transition_back_to_back() {
        let wasm = gain_half_wasm();
        let mut kernel = DSPKernel::new();
        assert!(kernel.load_wasm(&wasm));
        kernel.initialize(1, 1, 44100.0);

        let input = vec![1.0f32; 64];
        let mut warm = vec![0.0f32; 64];
        unsafe {
            let ip: *const f32 = input.as_ptr();
            let op: *mut f32 = warm.as_mut_ptr();
            kernel.process(&ip, &op, 1, 64);
        }

        let mut captured: Vec<f32> = Vec::new();
        const CHUNK: u32 = 64;
        let mut process_chunks = |kernel: &mut DSPKernel, captured: &mut Vec<f32>, n: usize| {
            for _ in 0..n {
                let mut out = vec![0.0f32; CHUNK as usize];
                unsafe {
                    let ip: *const f32 = input.as_ptr();
                    let op: *mut f32 = out.as_mut_ptr();
                    kernel.process(&ip, &op, 1, CHUNK);
                }
                captured.extend_from_slice(&out);
            }
        };

        // Three back-to-back transitions, each followed by a brief end +
        // resume. After each transition the kernel must still produce
        // monotonic output (no per-sample step over threshold).
        for _ in 0..3 {
            kernel.begin_preset_transition();
            // Process during the held-mute window.
            process_chunks(&mut kernel, &mut captured, 8);
            // Mutate params under the mute (the bug we're protecting against).
            kernel.set_parameter(0, 1.0);
            kernel.set_parameter(1, 0.0);
            // End and let the FADE_IN start.
            kernel.end_preset_transition();
            // Process briefly so the FADE_IN actually runs (but maybe not to
            // completion) before the next `begin`.
            process_chunks(&mut kernel, &mut captured, 4);
        }
        // Process long enough to fully drain whatever fade is still in
        // flight after the last end.
        process_chunks(&mut kernel, &mut captured, 32);

        let mut max_delta = 0.0f32;
        let mut max_delta_idx = 0usize;
        for (i, w) in captured.windows(2).enumerate() {
            let d = (w[1] - w[0]).abs();
            if d > max_delta {
                max_delta = d;
                max_delta_idx = i;
            }
        }
        assert!(
            max_delta < 0.02,
            "step discontinuity {} at sample {} during back-to-back transitions",
            max_delta, max_delta_idx
        );

        assert!(!kernel.transition_active(),
                "transition should be inactive at end of test");
    }

    /// Regression test for PR #215 review: after a swap completes, the *old*
    /// backend is parked in `pending_backend` for deferred drop. Benchmark must
    /// not pick it — it should run on the live backend (the one just swapped
    /// in). Verified indirectly by checking that `pending_backend` is still
    /// populated after `benchmark_process()` returns, which proves the
    /// pending slot was not taken/drained by the benchmark path.
    #[test]
    fn test_benchmark_process_after_completed_swap() {
        let wasm_a = gain_half_wasm();
        let wasm_b = wat::parse_str(r#"
            (module
              (memory (export "memory") 1)
              (func (export "get_block_info_ptr") (result i32) (i32.const 16))
              (func (export "get_input_ptr")      (result i32) (i32.const 1024))
              (func (export "get_output_ptr")     (result i32) (i32.const 32768))
              (func (export "process")
                (local $i i32)
                (local $total i32)
                (local.set $total
                  (i32.mul
                    (i32.load (i32.const 16))
                    (i32.load (i32.const 20))))
                (block $break
                  (loop $loop
                    (br_if $break (i32.ge_u (local.get $i) (local.get $total)))
                    (f32.store
                      (i32.add (i32.const 32768) (i32.mul (local.get $i) (i32.const 4)))
                      (f32.const 0.0)
                    )
                    (local.set $i (i32.add (local.get $i) (i32.const 1)))
                    (br $loop)
                  )
                )
              )
            )
        "#).expect("Failed to parse silence WAT");

        let mut kernel = DSPKernel::new();
        assert!(kernel.load_wasm(&wasm_a));
        kernel.initialize(1, 1, 44100.0);

        // Stage B and pump enough audio to complete fade-out + fade-in so the
        // swap has fully landed and `swap_phase` is back to IDLE. At that
        // point pending holds the *old* A and live holds the new B.
        // Need ≥ 1322 samples (15 ms × 2 fade @ 44.1 kHz); 32 × 64 = 2048.
        assert!(kernel.load_wasm(&wasm_b));
        let input = vec![1.0f32; 64];
        for _ in 0..32 {
            let mut out = vec![0.0f32; 64];
            unsafe {
                let ip: *const f32 = input.as_ptr();
                let op: *mut f32 = out.as_mut_ptr();
                kernel.process(&ip, &op, 1, 64);
            }
        }
        assert_eq!(
            kernel.swap_phase.load(Ordering::Acquire),
            SWAP_PHASE_IDLE,
            "swap should have fully drained"
        );
        assert!(
            kernel.pending_backend.lock().unwrap().is_some(),
            "pending should still hold the old backend parked for deferred drop"
        );

        let result = kernel.benchmark_process();
        assert!(result.is_some());
        assert!(result.unwrap() > 0.0);

        // Pending must still be intact — the fix routes benchmark to the live
        // slot when not in FADE_OUT, so the parked old backend is untouched.
        assert!(
            kernel.pending_backend.lock().unwrap().is_some(),
            "benchmark should not have taken the parked pending backend"
        );
    }

    /// Regression test for Seer finding on `9df9ee1`: benchmarking while a
    /// swap is still in flight used to hold `pending_backend.lock()` for
    /// ~50-100 ms, blocking the audio thread's `perform_swap_locked` and
    /// producing a silence dropout. The fix polls `swap_phase` until the
    /// audio thread has completed the swap, then benchmarks the live slot
    /// and never touches `pending_backend`. With no audio thread running to
    /// advance the swap, the poll must time out and return `None` rather
    /// than grabbing the pending lock and stalling the (would-be) audio
    /// thread.
    #[test]
    fn test_benchmark_process_times_out_if_swap_never_completes() {
        use std::sync::atomic::Ordering;

        let wasm_a = gain_half_wasm();
        let wasm_b = gain_half_wasm();

        let mut kernel = DSPKernel::new();
        assert!(kernel.load_wasm(&wasm_a));
        kernel.initialize(1, 1, 44100.0);

        // Stage B but don't pump audio — `pending_stage_request` stays set
        // and `swap_phase` stays `IDLE` (no audio thread to transition it).
        assert!(kernel.load_wasm(&wasm_b));
        assert!(
            kernel.pending_stage_request.load(Ordering::Acquire),
            "precondition: stage request should be pending before audio runs"
        );

        // Benchmark should time out (the polling loop waits up to 100 ms for
        // phase=IDLE with the request flag cleared; neither condition ever
        // becomes true because no audio thread is running).
        let start = std::time::Instant::now();
        let result = kernel.benchmark_process();
        let elapsed = start.elapsed();

        assert!(
            result.is_none(),
            "benchmark should time out while a swap is still pending"
        );
        assert!(
            elapsed >= std::time::Duration::from_millis(90),
            "benchmark should wait ~100 ms for swap completion before bailing, got {:?}",
            elapsed
        );

        // The staged pending backend must still be there — benchmark must
        // not have consumed or mutated it.
        assert!(
            kernel.pending_backend.lock().unwrap().is_some(),
            "pending backend should still hold the staged new backend"
        );
        assert!(
            kernel.pending_stage_request.load(Ordering::Acquire),
            "pending_stage_request should still be set after benchmark timeout"
        );
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
    fn test_demo_expiry_fades_out_smoothly() {
        // When the demo counter crosses the limit, the output should ramp from
        // full level to zero over ~DEMO_FADE_MS rather than producing a click.
        let mut kernel = DSPKernel::new();
        assert!(!kernel.is_licensed());
        kernel.initialize(1, 1, 48000.0);

        // Park the counter right at the limit so the very next buffer is gated.
        let limit = kernel.demo_limit_samples.load(Ordering::Relaxed);
        kernel.demo_samples_processed.store(limit, Ordering::Relaxed);

        // Process a buffer of non-zero input with no backend → passthrough shapes
        // by the fade envelope.
        let frames = 1024usize;
        let input = vec![0.5f32; frames];
        let mut output = vec![0.0f32; frames];
        let ip: *const f32 = input.as_ptr();
        let op: *mut f32 = output.as_mut_ptr();
        unsafe { kernel.process(&ip, &op, 1, frames as u32) };

        // First sample must not be the hard-cut zero — it should still be close
        // to the pre-expiry level (0.5) because the ramp has only moved one step.
        assert!(
            output[0] > 0.4,
            "expected fade-out to start from ~1.0, got first sample {}",
            output[0]
        );

        // No adjacent-sample jump should exceed a single fade step worth of level
        // (plus a small epsilon). At 48kHz / 5ms that's ~0.5 * (1/240) ≈ 0.0021.
        let max_step = 0.5 * (1000.0 / (DEMO_FADE_MS as f32 * 48000.0)) + 1e-5;
        for i in 1..frames {
            let d = (output[i] - output[i - 1]).abs();
            assert!(
                d <= max_step,
                "adjacent-sample jump {} at index {} exceeds max step {}",
                d,
                i,
                max_step
            );
        }

        // The fade must have fully completed within this buffer (5ms @ 48k = 240 samples).
        assert_eq!(
            output[frames - 1],
            0.0,
            "expected fade-out to have reached zero by end of buffer"
        );
    }

    #[test]
    fn test_demo_reset_fades_in_smoothly() {
        // After the demo gate has fully closed, resetting the counter should
        // ramp the output back up rather than jumping straight to full level.
        let mut kernel = DSPKernel::new();
        kernel.initialize(1, 1, 48000.0);

        // Drive the kernel past the limit so demo_gain reaches 0.
        let frames = 4096usize;
        let input = vec![0.5f32; frames];
        let mut output = vec![0.0f32; frames];
        let ip: *const f32 = input.as_ptr();
        let op: *mut f32 = output.as_mut_ptr();
        let iterations = (TEST_DEMO_LIMIT_SAMPLES / frames as u64) + 10;
        for _ in 0..iterations {
            unsafe { kernel.process(&ip, &op, 1, frames as u32) };
        }
        // Sanity: gate is fully closed, last buffer is fully silent.
        assert!(output.iter().all(|&s| s == 0.0));

        // Reset the demo counter (simulates license activation).
        kernel.reset_demo();

        // Process another buffer — output should ramp up from 0, not jump to 0.5.
        for s in output.iter_mut() {
            *s = 0.0;
        }
        unsafe { kernel.process(&ip, &op, 1, frames as u32) };

        assert!(
            output[0] < 0.01,
            "expected fade-in to start near zero, got first sample {}",
            output[0]
        );

        let max_step = 0.5 * (1000.0 / (DEMO_FADE_MS as f32 * 48000.0)) + 1e-5;
        for i in 1..frames {
            let d = (output[i] - output[i - 1]).abs();
            assert!(
                d <= max_step,
                "adjacent-sample jump {} at index {} exceeds max step {}",
                d,
                i,
                max_step
            );
        }

        // Ramp should have reached full level well within one 4096-sample buffer
        // at 48kHz (5ms fade = 240 samples).
        assert!(
            (output[frames - 1] - 0.5).abs() < 1e-5,
            "expected fade-in to have reached full level by end of buffer, got {}",
            output[frames - 1]
        );
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

        let script = "PARAM_NAMES = {0: \"Cutoff\", 1: \"Resonance\"}\n\ndef process(ctx):\n    for ch in range(len(ctx.inputs)):\n        ctx.outputs[ch][:ctx.frame_count] = ctx.inputs[ch][:ctx.frame_count]\n";
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

        let script = "def process(ctx):\n    for ch in range(len(ctx.inputs)):\n        ctx.outputs[ch][:ctx.frame_count] = ctx.inputs[ch][:ctx.frame_count]\n";
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
        let script1 = "PARAM_NAMES = {0: \"Rate\"}\n\ndef process(ctx):\n    for ch in range(len(ctx.inputs)):\n        ctx.outputs[ch][:ctx.frame_count] = ctx.inputs[ch][:ctx.frame_count]\n";
        let temp1 = temp_dir.join("test_param_names_1.py");
        std::fs::write(&temp1, script1).unwrap();

        let mut kernel = DSPKernel::new();
        kernel.load_script(&python_home, temp1.to_str().unwrap());
        assert!(!kernel.param_names_json_ptr().is_null());

        // Second: script WITHOUT param names — should clear
        let script2 = "def process(ctx):\n    for ch in range(len(ctx.inputs)):\n        ctx.outputs[ch][:ctx.frame_count] = ctx.inputs[ch][:ctx.frame_count]\n";
        let temp2 = temp_dir.join("test_param_names_2.py");
        std::fs::write(&temp2, script2).unwrap();

        kernel.load_script(&python_home, temp2.to_str().unwrap());
        assert!(kernel.param_names_json_ptr().is_null(), "Should be cleared after loading script without PARAM_NAMES");

        std::fs::remove_file(&temp1).ok();
        std::fs::remove_file(&temp2).ok();
    }

    /// A WAT module whose `process` function traps unconditionally via the
    /// `unreachable` instruction. Used to verify that benchmark_process
    /// captures the trap into kernel.last_error rather than swallowing it.
    /// Includes the buffer-getter exports so the backend lands in
    /// ModuleAllocated buffer_mode, matching the shape of a compiled Rust
    /// preset that crashes on first sample.
    const TRAPPING_WAT: &str = r#"
        (module
          (memory (export "memory") 1)
          (func (export "get_block_info_ptr") (result i32) (i32.const 16))
          (func (export "get_input_ptr")      (result i32) (i32.const 1024))
          (func (export "get_output_ptr")     (result i32) (i32.const 32768))
          (func (export "process")
            unreachable
          )
        )
    "#;

    #[test]
    fn test_benchmark_captures_runtime_trap() {
        // A script that compiles cleanly but traps on every block must
        // surface its trap message via kernel.last_error after the
        // post-load benchmark runs. Without the capture_backend_error
        // call at the end of benchmark_process, kernel.last_error would
        // stay None and the MCP get_error tool would lie about runtime
        // traps to anyone polling between compile_and_run and probe.
        let wasm_bytes = wat::parse_str(TRAPPING_WAT).expect("Failed to parse TRAPPING_WAT");

        let mut kernel = DSPKernel::new();
        kernel.initialize(2, 2, 48000.0);
        kernel.set_maximum_frames_to_render(64);
        assert!(kernel.last_error().is_none(), "Pre-load kernel.last_error should be None");

        let loaded = kernel.load_wasm(&wasm_bytes);
        assert!(loaded, "WASM should load successfully even though its process() traps");

        // The load itself runs `dsp_kernel_benchmark_process` via Swift
        // in production. In tests we trigger it manually.
        let _ = kernel.benchmark_process();

        // After the benchmark drained the trap, kernel.last_error must
        // contain the WASM trap message.
        let err = kernel.last_error();
        assert!(err.is_some(), "kernel.last_error should be Some after benchmark trapped");
        let msg = err.unwrap();
        assert!(
            msg.contains("WASM process error") || msg.to_lowercase().contains("unreachable"),
            "Trap message should mention WASM process error or unreachable; got: {}",
            msg
        );
    }
}
