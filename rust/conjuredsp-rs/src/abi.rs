//! ABI types shared between the WASM-side `setup!()` allocation and the
//! host-side `wasm_backend.rs` writer. One source of truth for the layout.
//!
//! Today the only resident is [`BlockInfo`], the structured replacement
//! for the legacy 5-arg `process(input_ptr, output_ptr, channel_count,
//! frame_count, sample_rate)` signature. `setup!()` allocates a
//! `BLOCK_INFO_BUF: BlockInfo` static at a known address, the host writes
//! the per-block scalars into it before each render call, and the
//! WASM-side `process!` macro (step 4 of the modernization plan) reads
//! them back from there.

/// Per-block scalars passed from the host into the WASM module via the
/// shared `BLOCK_INFO_BUF` channel. Layout is `#[repr(C)]` so the host
/// can write into the same struct it reads on the wasm side.
#[repr(C)]
#[derive(Copy, Clone, Debug)]
pub struct BlockInfo {
    /// Number of audio frames the host expects `process()` to render
    /// this block. Bounded by `MAX_FR` (see `setup!()`).
    pub frame_count: u32,
    /// Active channel count (input == output for AU effects).
    pub channel_count: u32,
    /// Render sample rate in Hz.
    pub sample_rate: f32,
}

impl BlockInfo {
    /// Zero-initialized — safe `const` default usable in
    /// `static BLOCK_INFO_BUF: BlockInfo = BlockInfo::zeroed();`.
    pub const fn zeroed() -> Self {
        Self {
            frame_count: 0,
            channel_count: 0,
            sample_rate: 0.0,
        }
    }
}
