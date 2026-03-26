use crate::kernel::TransportState;
use crate::params::{ParamMetadata, PARAM_COUNT};
use std::collections::HashMap;

/// Trait for pluggable DSP processing backends (Python, WASM, etc.).
///
/// Implementations must be real-time safe in `process()`:
/// - No allocations, no locks, no syscalls
/// - Pre-allocate everything in `initialize()`
pub trait Backend {
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
}
