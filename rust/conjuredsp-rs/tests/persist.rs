//! Tests for [`conjuredsp::Persist`] and the [`persist!`] macro.
//!
//! Companion to `tests/persist_mut.rs`; the structural guarantee of
//! `Persist` is that it has no closure-based mutator (so the
//! read-snapshot-mutate-writeback footgun is a compile error), which
//! is documented by the trybuild-style negative test at the bottom.

use conjuredsp::*;

persist!(SCALAR_F64: f64 = 0.0);
persist!(SCALAR_USIZE: usize = 0);
persist!(SCALAR_BOOL: bool = false);

#[derive(Copy, Clone, PartialEq, Debug)]
enum Mode {
    Quiet,
    Loud,
}

persist!(SCALAR_ENUM: Mode = Mode::Quiet);

persist!(SMALL_ARRAY: [f32; 4] = [0.0; 4]);

#[test]
fn scalar_get_returns_init_value() {
    assert_eq!(SCALAR_F64.get(), 0.0);
    assert_eq!(SCALAR_USIZE.get(), 0);
    assert!(!SCALAR_BOOL.get());
    assert_eq!(SCALAR_ENUM.get(), Mode::Quiet);
}

#[test]
fn scalar_set_then_get_round_trips() {
    SCALAR_F64.set(1.5);
    assert_eq!(SCALAR_F64.get(), 1.5);
    SCALAR_F64.set(0.0);  // reset so other tests aren't order-sensitive
}

#[test]
fn scalar_replace_returns_old_and_stores_new() {
    SCALAR_USIZE.set(7);
    let old = SCALAR_USIZE.replace(42);
    assert_eq!(old, 7);
    assert_eq!(SCALAR_USIZE.get(), 42);
    SCALAR_USIZE.set(0);
}

#[test]
fn read_snapshot_mutate_writeback_works() {
    // The intended idiom for scalar-counter shapes — no with_mut needed.
    SCALAR_USIZE.set(0);
    for _ in 0..10 {
        SCALAR_USIZE.set(SCALAR_USIZE.get().wrapping_add(1));
    }
    assert_eq!(SCALAR_USIZE.get(), 10);
    SCALAR_USIZE.set(0);
}

#[test]
fn copy_array_get_set_works() {
    SMALL_ARRAY.set([1.0, 2.0, 3.0, 4.0]);
    let a = SMALL_ARRAY.get();
    assert_eq!(a, [1.0, 2.0, 3.0, 4.0]);
    // Read-snapshot-mutate-writeback for small Copy arrays is fine —
    // Persist<[T;N]> just round-trips the array bytes on get/set.
    let mut b = SMALL_ARRAY.get();
    b[2] = 99.0;
    SMALL_ARRAY.set(b);
    assert_eq!(SMALL_ARRAY.get()[2], 99.0);
    SMALL_ARRAY.set([0.0; 4]);
}

// Structural-safety: `Persist<T>` has no `with_mut` closure API, so the
// silent-miscompile read-snapshot-mutate-writeback shape can't even
// compile. The corresponding `compile_fail` doc-test lives on the
// `Persist` struct in src/persist.rs so it's picked up by `cargo test`.
