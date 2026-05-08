//! Regression test for the `telemetry!` empty-form toolchain bug.
//!
//! Previously, an author who wrote `telemetry!()` (after the compiler
//! suggested the `!` from a bare `telemetry()` call) or a `telemetry!{}`
//! placeholder hit a confusing `*mut f32` vs `*mut [f32; 4096]` mismatch
//! deep inside the macro expansion — caused by the trait impl
//! generating an `as_mut_ptr()` call against a zero-length slot array.
//! All three empty forms now no-op cleanly so the script compiles and
//! the author can fill the body in.

use conjuredsp::*;

setup!();

telemetry! {}
telemetry!();
telemetry! {,}

#[test]
fn empty_telemetry_compiles() {}
