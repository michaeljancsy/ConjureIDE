//! Bit-exact passthrough backend.
//!
//! Installed by `DSPKernel::load_script` / `load_wasm` on the `Err` branch
//! so the user hears something obviously different from the new preset
//! they tried to load — instead of the previously-loaded backend silently
//! continuing to render audio with new param indices wired to old DSP
//! (which feels like the new preset works but actually isn't).
//!
//! No params, no metadata, no state, no telemetry — every optional
//! `Backend` method falls through to its trait default. The kernel still
//! sees a live backend, so the swap state machine, profiler, and audio
//! thread fast paths all behave normally.
use crate::backend::{Backend, SidechainInput, StateSnapshot};
use crate::kernel::TransportState;
use crate::params::PARAM_COUNT;

pub struct PassthroughBackend;

impl PassthroughBackend {
    pub fn new() -> Self {
        PassthroughBackend
    }
}

impl Default for PassthroughBackend {
    fn default() -> Self {
        Self::new()
    }
}

impl Backend for PassthroughBackend {
    fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
        self
    }

    fn initialize(&mut self, _channel_count: usize, _sample_rate: f64, _max_frames: u32) {
        // Nothing to allocate — the process loop reads inputs and writes
        // outputs directly without intermediate buffers.
    }

    fn deinitialize(&mut self) {
        // Same — no resources to release.
    }

    /// Copy `inputs[ch]` to `outputs[ch]` byte-for-byte. Returns `true`
    /// so the kernel's audio thread treats this as a successful render
    /// (the per-block `if !produced { passthrough() }` fallback is for
    /// `None` backends and per-block process errors, not for this path).
    unsafe fn process(
        &mut self,
        inputs: &[*const f32],
        outputs: &[*mut f32],
        channel_count: usize,
        frame_count: usize,
        _sample_rate: f64,
        _params: &[f32; PARAM_COUNT],
        _transport: &TransportState,
        _sidechain: SidechainInput<'_>,
        _state: &StateSnapshot,
    ) -> bool {
        for ch in 0..channel_count {
            let src = std::slice::from_raw_parts(inputs[ch], frame_count);
            let dst = std::slice::from_raw_parts_mut(outputs[ch], frame_count);
            dst.copy_from_slice(src);
        }
        true
    }

    fn last_error(&self) -> Option<&str> {
        None
    }
}
