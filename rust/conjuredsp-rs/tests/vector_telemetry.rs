//! Integration tests for the vector telemetry path emitted by the
//! `telemetry!` macro. Verifies that `set_telemetry_vector` on
//! `Context` (provided via the macro's local extension trait):
//!
//! - copies a slice into the macro-emitted per-slot static buffer
//! - bounds-checks the slot index (silent no-op past the slot count)
//! - silently no-ops when the slot is declared as scalar (shape guard)
//! - truncates slices longer than `MAX_FRAMES` instead of panicking
//!
//! Also confirms the metadata JSON emits `shape`.
//!
//! Tests run on the native target (not wasm32). The macro's
//! `#[no_mangle] pub extern "C"` exports compile fine on native, but
//! their `*const f32 as i32` pointer return-type *truncates* 64-bit
//! addresses, so the tests read the macro-emitted statics directly
//! (legitimate at the test site since the macro expands into this
//! file's module scope) instead of round-tripping through the export.

use conjuredsp::*;

setup!();

telemetry! {
    SCALAR_SLOT = scalar_telemetry().unit("dB"),
    VECTOR_SLOT = vector_telemetry(),
    SECOND_VEC  = vector_telemetry().unit(""),
}

// Build a Context with audio buffers we won't use; only the
// telemetry-vector path is exercised. Pass static-rooted pointers for
// params/telemetry so the Context outlives the call frame.
static mut UNUSED_PARAMS: [f32; 16] = [0.0; 16];
static mut UNUSED_TELE: [f32; conjuredsp::TELEMETRY_LEN] = [0.0; conjuredsp::TELEMETRY_LEN];

fn make_ctx(frame_count: i32) -> conjuredsp::Context {
    unsafe {
        conjuredsp::Context::new(
            core::ptr::null(),
            core::ptr::null_mut(),
            0,
            frame_count,
            48000.0,
            UNUSED_PARAMS.as_ptr(),
            UNUSED_TELE.as_mut_ptr(),
        )
    }
}

fn read_vec_slot(slot: usize, len: usize) -> alloc::vec::Vec<f32> {
    unsafe { TELEMETRY_VEC_BUFS[slot][..len].to_vec() }
}

fn zero_vec_slot(slot: usize) {
    unsafe {
        for v in TELEMETRY_VEC_BUFS[slot].iter_mut() {
            *v = 0.0;
        }
    }
}

#[test]
fn vector_write_lands_in_macro_buffer() {
    zero_vec_slot(VECTOR_SLOT);
    let ctx = make_ctx(8);
    let samples = [1.0_f32, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0];
    ctx.set_telemetry_vector(VECTOR_SLOT, &samples);

    let buf = read_vec_slot(VECTOR_SLOT, 8);
    assert_eq!(buf, samples);
}

#[test]
fn vector_writes_to_distinct_slots_dont_alias() {
    zero_vec_slot(VECTOR_SLOT);
    zero_vec_slot(SECOND_VEC);
    let ctx = make_ctx(4);
    let a = [10.0_f32, 11.0, 12.0, 13.0];
    let b = [20.0_f32, 21.0, 22.0, 23.0];
    ctx.set_telemetry_vector(VECTOR_SLOT, &a);
    ctx.set_telemetry_vector(SECOND_VEC, &b);

    assert_eq!(read_vec_slot(VECTOR_SLOT, 4), a);
    assert_eq!(read_vec_slot(SECOND_VEC, 4), b);
}

#[test]
fn vector_write_to_scalar_slot_is_silent_noop() {
    zero_vec_slot(SCALAR_SLOT);
    let ctx = make_ctx(4);
    let samples = [99.0_f32; 4];
    // Scalar slot — should silently no-op. Buffer for the slot exists
    // (every slot has one) but the macro guards against scalar writes.
    ctx.set_telemetry_vector(SCALAR_SLOT, &samples);

    let buf = read_vec_slot(SCALAR_SLOT, 4);
    assert!(
        buf.iter().all(|&v| v == 0.0),
        "scalar-slot buffer must remain untouched, got {buf:?}"
    );
}

#[test]
fn vector_write_out_of_range_slot_is_silent_noop() {
    let ctx = make_ctx(4);
    let samples = [1.0_f32; 4];
    // Past the declared slot count — silent no-op (no panic, no UB).
    ctx.set_telemetry_vector(99, &samples);
    ctx.set_telemetry_vector(usize::MAX, &samples);
}

#[test]
fn vector_write_truncates_oversized_slice() {
    zero_vec_slot(VECTOR_SLOT);
    let ctx = make_ctx(4);
    // Slice longer than MAX_FRAMES — must truncate, not panic.
    let big: alloc::vec::Vec<f32> = (0..(conjuredsp::MAX_FRAMES + 100))
        .map(|i| i as f32)
        .collect();
    ctx.set_telemetry_vector(VECTOR_SLOT, &big);

    let buf = read_vec_slot(VECTOR_SLOT, conjuredsp::MAX_FRAMES);
    assert_eq!(buf[0], 0.0);
    assert_eq!(
        buf[conjuredsp::MAX_FRAMES - 1],
        (conjuredsp::MAX_FRAMES - 1) as f32
    );
}

#[test]
fn telemetry_metadata_json_includes_shape() {
    // TELEMETRY_METADATA is the macro-emitted static; read it directly
    // (the i32 export truncates on 64-bit native, see module docs).
    let s: &str = TELEMETRY_METADATA;
    assert!(s.contains(r#""shape":"scalar""#), "expected scalar shape in {s}");
    assert!(s.contains(r#""shape":"vector""#), "expected vector shape in {s}");
    assert!(s.contains(r#""name":"SCALAR_SLOT""#));
    assert!(s.contains(r#""name":"VECTOR_SLOT""#));
}

extern crate alloc;
