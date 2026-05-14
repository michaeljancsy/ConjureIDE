//! Tests for [`conjuredsp::PersistMut`] and the [`persist_mut!`] macro.
//!
//! Companion to `tests/persist.rs`; covers in-place mutation through
//! `with_mut` and the debug-only reentrancy panic.

use conjuredsp::*;

persist_mut!(BUF_4: [f32; 4] = [0.0; 4]);

// Modest stand-in for the production 384 KB delay buffer
// (`[[f32; 48_000]; 2]`). Keeps the test fast while exercising the
// large-array path.
persist_mut!(STEREO_DELAY: [[f32; 1_024]; 2] = [[0.0; 1_024]; 2]);

#[test]
fn with_mut_writes_propagate_to_next_read() {
    BUF_4.with_mut(|b| {
        b[0] = 1.0;
        b[1] = 2.0;
        b[2] = 3.0;
        b[3] = 4.0;
    });
    BUF_4.with_mut(|b| {
        assert_eq!(b, &[1.0, 2.0, 3.0, 4.0]);
        // Reset for other tests.
        *b = [0.0; 4];
    });
}

#[test]
fn with_mut_can_return_a_value() {
    BUF_4.with_mut(|b| b[0] = 7.0);
    let v = BUF_4.with_mut(|b| b[0]);
    assert_eq!(v, 7.0);
    BUF_4.with_mut(|b| *b = [0.0; 4]);
}

#[test]
fn nested_2d_array_buffer_supports_per_cell_mutation() {
    // Exercises the access shape every delay/reverb preset uses.
    STEREO_DELAY.with_mut(|buf| {
        buf[0][100] = 0.5;
        buf[1][200] = -0.5;
    });
    STEREO_DELAY.with_mut(|buf| {
        assert_eq!(buf[0][100], 0.5);
        assert_eq!(buf[1][200], -0.5);
        // Reset
        for row in buf.iter_mut() {
            row.fill(0.0);
        }
    });
}

// Reentrancy: debug builds enforce the contract via a RAII guard that
// panics on re-entry (wasm32) or via `std::sync::Mutex` which deadlocks
// on re-entry (host). The wasm panic shape is testable; the host
// deadlock shape is not (it would hang the runner), so the explicit
// reentrancy test below is wasm-only. Host coverage for the guarantee
// comes from `Mutex`'s well-documented semantics.
//
// Use a dedicated `static` so a flaky run doesn't poison BUF_4 for
// other tests.
persist_mut!(REENTRY_PROBE: [u8; 4] = [0u8; 4]);

#[cfg(all(debug_assertions, target_arch = "wasm32"))]
#[test]
#[should_panic(expected = "reentrant PersistMut::with_mut")]
fn reentrant_with_mut_panics_in_debug() {
    REENTRY_PROBE.with_mut(|_| {
        REENTRY_PROBE.with_mut(|_| {});
    });
}

#[test]
fn repeated_non_reentrant_with_mut_calls_are_fine() {
    // The guard (wasm Cell or host Mutex) must release after Drop so
    // sequential non-reentrant calls work.
    BUF_4.with_mut(|_| {});
    BUF_4.with_mut(|_| {});
    BUF_4.with_mut(|_| {});
}
