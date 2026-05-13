//! Persistent state primitives for DSP scripts.
//!
//! DSP scripts nearly always need to carry state from one render block
//! to the next — an envelope follower's level, a delay line's buffer,
//! a filter's previous sample, a ring-buffer's write position. The
//! pre-modernization pattern was raw `static mut` plus `unsafe { … }`
//! sprinkled at every access. Rust 2024 (via the
//! `static_mut_refs` deny-by-default lint) closes that path; this module
//! gives presets two replacements split along whether mutation needs
//! in-place access:
//!
//! - [`Persist<T>`] for scalar / `Copy` state that's read or recomputed
//!   wholesale — read/write through `get` / `set` / `replace`. **Has no
//!   closure API**, so the read-snapshot-mutate-writeback pitfall is a
//!   compile error rather than a silent miscompile.
//! - [`PersistMut<T>`] for state mutated in place during the render
//!   loop — DSP blocks like `Biquad` / `Lfo` / `DelayLine` whose
//!   `&mut self` methods (`process_sample`, `tick`, `write`) are the
//!   natural usage shape, plus raw buffers written linearly per block
//!   (delay write-through, IR convolution scratch, scope rings).
//!   Mutates via `with_mut(|val| …)` with a documented reentrancy
//!   contract; debug builds enforce that contract with a RAII guard,
//!   release builds trust the author.
//!
//! Storage shape is cfg-gated by target:
//!
//! - **wasm32** (the only target that ships to users): a bare
//!   `UnsafeCell` with an `unsafe impl Sync` that's sound because the
//!   AU host never calls `process()` reentrantly on the same instance.
//! - **host** (cargo test on aarch64/x86_64): a `std::sync::Mutex`
//!   so the integration tests under `tests/persist*.rs` stay sound when
//!   `cargo test` runs test functions in parallel. The lock is held for
//!   exactly the duration of the closure / scalar access; no
//!   cross-block contention exists since each test owns its own static.
//!
//! `static mut` remains a viable fallback under edition 2024 if either
//! primitive ever hits a limitation, via `&raw mut X` / `&raw const X`.
//! Prefer the macros (`persist!` / `persist_mut!`) over the fallback —
//! they're 2024-clean by construction and read more cleanly at the call
//! site.

#[cfg(target_arch = "wasm32")]
use core::cell::UnsafeCell;
#[cfg(not(target_arch = "wasm32"))]
use std::sync::Mutex;

/// Persistent scalar (or other `Copy` type) state between render blocks.
///
/// Access via `get` / `set` / `replace`. No closure API — the
/// `static_mut_refs`-equivalent footgun (a `with_mut` closure that
/// captures `&self` and lets a re-entrant caller observe partial
/// writes) is structurally impossible.
///
/// # Example
///
/// ```ignore
/// use conjuredsp::*;
///
/// persist!(ENVELOPE: f64 = 0.0);
/// persist!(WRITE_POS: usize = 0);
///
/// // Read a fresh snapshot every block, update, store back.
/// let env = ENVELOPE.get() * 0.95 + new_sample.abs() as f64 * 0.05;
/// ENVELOPE.set(env);
///
/// // Increment in place — still scalar; no with_mut.
/// WRITE_POS.set(WRITE_POS.get().wrapping_add(1));
/// ```
///
/// # Why no `with_mut`?
///
/// A single `with_mut`-style API for both scalars and in-place state
/// invites `X.with_mut(|x| { *x = X.get() + 1 })` — the read-snapshot-
/// mutate-writeback shape that silently miscompiles in release. By
/// keeping scalars on `get`/`set` and in-place state on a separate
/// [`PersistMut`] type, calling `with_mut` on a `Persist` becomes a
/// "method not found" compile error, not a runtime hazard:
///
/// ```compile_fail
/// use conjuredsp::Persist;
/// static X: Persist<f64> = Persist::new(0.0);
/// X.with_mut(|v| *v = 1.0);  // E0599: method `with_mut` not found
/// ```
#[cfg(target_arch = "wasm32")]
pub struct Persist<T: Copy>(UnsafeCell<T>);

#[cfg(not(target_arch = "wasm32"))]
pub struct Persist<T: Copy + Send>(Mutex<T>);

// SAFETY: WASM modules are single-threaded; the host never calls
// `process()` reentrantly on the same instance. On non-wasm targets
// Mutex<T> already provides `Sync` (for `T: Send`), so no manual impl
// is needed.
#[cfg(target_arch = "wasm32")]
unsafe impl<T: Copy> Sync for Persist<T> {}

#[cfg(target_arch = "wasm32")]
impl<T: Copy> Persist<T> {
    /// Wrap an initial value. `const` so it can sit in a `static`.
    pub const fn new(v: T) -> Self {
        Self(UnsafeCell::new(v))
    }

    /// Read the current value.
    #[inline]
    pub fn get(&self) -> T {
        // SAFETY: WASM single-threaded; no reentrant access.
        unsafe { *self.0.get() }
    }

    /// Overwrite the stored value.
    #[inline]
    pub fn set(&self, v: T) {
        // SAFETY: WASM single-threaded; no reentrant access.
        unsafe {
            *self.0.get() = v;
        }
    }

    /// Atomically (single-threaded) replace and return the old value.
    #[inline]
    pub fn replace(&self, v: T) -> T {
        let old = self.get();
        self.set(v);
        old
    }
}

#[cfg(not(target_arch = "wasm32"))]
impl<T: Copy + Send> Persist<T> {
    /// Wrap an initial value. `const` so it can sit in a `static`.
    pub const fn new(v: T) -> Self {
        Self(Mutex::new(v))
    }

    /// Read the current value.
    #[inline]
    pub fn get(&self) -> T {
        *self.0.lock().expect("Persist Mutex poisoned")
    }

    /// Overwrite the stored value.
    #[inline]
    pub fn set(&self, v: T) {
        *self.0.lock().expect("Persist Mutex poisoned") = v;
    }

    /// Replace and return the old value.
    #[inline]
    pub fn replace(&self, v: T) -> T {
        let mut g = self.0.lock().expect("Persist Mutex poisoned");
        let old = *g;
        *g = v;
        old
    }
}

/// Persistent state mutated in place via
/// [`with_mut`](PersistMut::with_mut).
///
/// Choose this over [`Persist<T>`] when the value is mutated during the
/// render loop — either a DSP block whose `&mut self` methods
/// (`Biquad::process_sample`, `Lfo::tick`, `DelayLine::write`) are the
/// natural usage shape, or a raw buffer written linearly per block
/// (delay-line write-through, IR convolution scratch, scope/oscilloscope
/// ring). The closure body gets `&mut T`, so methods can run without a
/// read-modify-write round-trip through `get`/`set`.
///
/// # Reentrancy contract
///
/// `with_mut` borrows the wrapped value mutably for the closure's
/// lifetime. The closure must not call any other method on the same
/// `PersistMut` — aliased `&mut T` is undefined behaviour even on a
/// single thread. Debug builds enforce the contract with a panic-safe
/// RAII guard; release builds trust the author. The release failure
/// mode is **silent miscompilation**, not panic, so the debug check is
/// a test tripwire only.
///
/// # Example
///
/// ```ignore
/// use conjuredsp::*;
///
/// persist_mut!(DELAYS: [DelayLine<48000>; 2] = [const { DelayLine::new() }; 2]);
///
/// // Inside process():
/// DELAYS.with_mut(|d| {
///     d[channel].write(sample);
///     let y = d[channel].read(delay_samples);
/// });
/// ```
#[cfg(target_arch = "wasm32")]
pub struct PersistMut<T> {
    inner: UnsafeCell<T>,
    #[cfg(debug_assertions)]
    in_use: core::cell::Cell<bool>,
}

#[cfg(not(target_arch = "wasm32"))]
pub struct PersistMut<T: Send>(Mutex<T>);

// SAFETY: WASM modules are single-threaded; the host never calls
// `process()` reentrantly on the same instance. On non-wasm targets
// Mutex<T> already provides `Sync` (for `T: Send`), so no manual impl
// is needed.
#[cfg(target_arch = "wasm32")]
unsafe impl<T> Sync for PersistMut<T> {}

#[cfg(target_arch = "wasm32")]
impl<T> PersistMut<T> {
    /// Wrap an initial value. `const` so it can sit in a `static`.
    pub const fn new(v: T) -> Self {
        Self {
            inner: UnsafeCell::new(v),
            #[cfg(debug_assertions)]
            in_use: core::cell::Cell::new(false),
        }
    }

    /// Run `f` with exclusive access to the wrapped value.
    ///
    /// # Reentrancy
    ///
    /// `f` MUST NOT call any other method on the same `PersistMut`.
    /// Aliased `&mut T` is undefined behaviour even single-threaded.
    /// Debug builds enforce this contract with a RAII guard that
    /// panics on reentry (and resets cleanly on panic via `Drop`).
    /// Release builds skip the guard.
    #[inline]
    pub fn with_mut<R>(&self, f: impl FnOnce(&mut T) -> R) -> R {
        #[cfg(debug_assertions)]
        let _guard = {
            assert!(
                !self.in_use.replace(true),
                "reentrant PersistMut::with_mut"
            );
            struct Reset<'a>(&'a core::cell::Cell<bool>);
            impl Drop for Reset<'_> {
                fn drop(&mut self) {
                    self.0.set(false);
                }
            }
            Reset(&self.in_use)
        };
        // SAFETY: We hold &self; the reentrancy guard (debug) or the
        // documented contract (release) prevents aliased &mut T.
        unsafe { f(&mut *self.inner.get()) }
    }
}

#[cfg(not(target_arch = "wasm32"))]
impl<T: Send> PersistMut<T> {
    /// Wrap an initial value. `const` so it can sit in a `static`.
    pub const fn new(v: T) -> Self {
        Self(Mutex::new(v))
    }

    /// Run `f` with exclusive access to the wrapped value.
    ///
    /// On host the Mutex itself is the reentrancy contract: a recursive
    /// `with_mut` on the same instance will deadlock rather than alias
    /// `&mut T`. The wasm32 variant uses an explicit `Cell<bool>` guard
    /// instead since `std::sync::Mutex` isn't appropriate there.
    #[inline]
    pub fn with_mut<R>(&self, f: impl FnOnce(&mut T) -> R) -> R {
        let mut guard = self.0.lock().expect("PersistMut Mutex poisoned");
        f(&mut *guard)
    }
}
