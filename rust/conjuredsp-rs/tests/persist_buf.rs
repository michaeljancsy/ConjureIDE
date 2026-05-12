//! Tests for [`conjuredsp::PersistBuf`] and the [`persist_buf!`] macro.
//!
//! Companion to `tests/persist.rs`; covers in-place buffer mutation
//! through `with_mut` and the debug-only reentrancy panic.

use conjuredsp::*;

persist_buf!(BUF_4: [f32; 4] = [0.0; 4]);

// Modest stand-in for the production 384 KB delay buffer
// (`[[f32; 48_000]; 2]`). Keeps the test fast while exercising the
// large-array path.
persist_buf!(STEREO_DELAY: [[f32; 1_024]; 2] = [[0.0; 1_024]; 2]);

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
// panics on re-entry. Release builds skip the check (silent UB if the
// author violates the contract; the test runs under debug so the
// assertion fires).
//
// Use a dedicated `static` so a flaky run doesn't poison BUF_4 for
// other tests.
persist_buf!(REENTRY_PROBE: [u8; 4] = [0u8; 4]);

#[cfg(debug_assertions)]
#[test]
#[should_panic(expected = "reentrant PersistBuf::with_mut")]
fn reentrant_with_mut_panics_in_debug() {
    REENTRY_PROBE.with_mut(|_| {
        REENTRY_PROBE.with_mut(|_| {});
    });
}

#[cfg(debug_assertions)]
#[test]
fn guard_resets_after_normal_return_so_repeated_calls_are_fine() {
    // The RAII guard must reset `in_use` on Drop so a non-reentrant
    // call pattern works for the next invocation.
    BUF_4.with_mut(|_| {});
    BUF_4.with_mut(|_| {}); // would panic if guard didn't reset
    BUF_4.with_mut(|_| {});
}
