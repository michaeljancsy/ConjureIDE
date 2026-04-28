use crate::kernel::TransportState;
use crate::params::{ParamMetadata, TelemetryMetadata, PARAM_COUNT, TELEMETRY_LEN};
use std::any::Any;
use std::collections::HashMap;

/// Trait for pluggable DSP processing backends (Python, WASM, etc.).
///
/// Implementations must be real-time safe in `process()`:
/// - No allocations, no locks, no syscalls
/// - Pre-allocate everything in `initialize()`
pub trait Backend: Any {
    /// Downcast support for safe runtime type checking.
    fn as_any_mut(&mut self) -> &mut dyn Any;
    /// Called when render resources are allocated. Pre-allocate any per-channel
    /// buffers sized to `max_frames`.
    fn initialize(&mut self, channel_count: usize, sample_rate: f64, max_frames: u32);

    /// Called when render resources are deallocated. Drop per-channel buffers.
    fn deinitialize(&mut self);

    /// Process audio. Returns true on success, false to trigger passthrough fallback.
    ///
    /// `params` contains the DAW-automatable parameter values (0.0–1.0),
    /// snapshotted once per audio callback from atomic storage.
    ///
    /// Takes `&mut self` because some backends (e.g. wasmtime) require mutable
    /// access to their execution state during function calls.
    ///
    /// # Safety
    /// - `inputs` must contain `channel_count` valid `*const f32` pointers.
    /// - `outputs` must contain `channel_count` valid `*mut f32` pointers.
    /// - Each channel buffer must contain at least `frame_count` samples.
    unsafe fn process(
        &mut self,
        inputs: &[*const f32],
        outputs: &[*mut f32],
        channel_count: usize,
        frame_count: usize,
        sample_rate: f64,
        params: &[f32; PARAM_COUNT],
        transport: &TransportState,
    ) -> bool;

    /// Returns the last error message, if any.
    fn last_error(&self) -> Option<&str>;

    /// Returns script-declared parameter names, keyed by address (0–15).
    /// Empty map means no names were declared (backward compatible).
    fn param_names(&self) -> HashMap<u8, String> {
        HashMap::new()
    }

    /// Returns rich parameter metadata if the script declares a `PARAMS` dict.
    /// When present, the kernel denormalizes 0–1 values to actual ranges before
    /// passing to the backend (Python only; WASM receives raw 0–1).
    fn param_metadata(&self) -> Option<&[ParamMetadata]> {
        None
    }

    /// Returns script-declared algorithmic latency in samples.
    /// Zero means no latency (default for backward compatibility).
    /// Used by the AU host to report `AUAudioUnit.latency` for DAW compensation.
    fn latency_samples(&self) -> u32 {
        0
    }

    /// Returns the backend's current memory usage in bytes.
    /// WASM returns linear memory size; Python returns 0 (use process RSS instead).
    fn memory_bytes(&self) -> u64 {
        0
    }

    /// Returns the script-declared telemetry slot metadata, if any.
    /// `None` means the script didn't call `telemetry!()` / declare a
    /// `TELEMETRY` dict — host treats as zero slots and never reads
    /// from the buffer. Default impl: no telemetry.
    fn telemetry_metadata(&self) -> Option<&[TelemetryMetadata]> {
        None
    }

    /// Snapshot the latest telemetry values written by the most recent
    /// `process()` call. Backends that publish telemetry copy from
    /// their internal buffer (WASM linear memory's TELEMETRY_BUF, or
    /// the Python TELEMETRY dict) into `out`. Slots not written by
    /// the script remain zero.
    ///
    /// Default impl: leaves `out` untouched. The kernel still snapshots
    /// it into atomics each block, which means a backend without
    /// telemetry surface produces an all-zeros snapshot — the right
    /// thing.
    fn read_telemetry(&self, _out: &mut [f32; TELEMETRY_LEN]) {}

    /// Read a single vector telemetry slot's per-frame values from the
    /// backend's private buffer into `out`. Called by the kernel
    /// immediately after `process()` for every slot whose
    /// `TelemetryMetadata.shape == "vector"`. Implementations copy
    /// up to `frame_count` f32 values starting from the slot's base
    /// pointer (WASM linear memory offset, or numpy `data_ptr()`).
    ///
    /// `slot_index` is the slot's position in
    /// [`Backend::telemetry_metadata`] — the same index a script's
    /// const passes to `set_telemetry_vector`.
    ///
    /// Default impl: leaves `out` untouched. Backends without vector
    /// telemetry support inherit the no-op, and the kernel publishes
    /// zeros to the host.
    fn read_telemetry_vec(
        &self,
        _slot_index: usize,
        _frame_count: usize,
        _out: &mut [f32],
    ) {
    }
}
