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
//! - [`Persist<T>`] for scalar / `Copy` state — read/write through
//!   `get` / `set` / `replace`. **Has no closure API**, so the
//!   read-snapshot-mutate-writeback pitfall is a compile error rather
//!   than a silent miscompile.
//! - [`PersistBuf<T>`] for in-place mutation of large arrays (delay
//!   buffers, ring buffers in reverbs/chorus/flanger). Mutates via
//!   `with_mut(|buf| …)` with a documented reentrancy contract; debug
//!   builds enforce that contract with a RAII guard, release builds
//!   trust the author.
//!
//! Both are wrapped in [`UnsafeCell`] and assert `Sync` unconditionally,
//! justified by WASM's single-threaded execution model — the AU host
//! never calls `process()` reentrantly on the same instance.
//!
//! `static mut` remains a viable fallback under edition 2024 if either
//! primitive ever hits a limitation, via `&raw mut X` / `&raw const X`.
//! Prefer the macros (`persist!` / `persist_buf!`) over the fallback —
//! they're 2024-clean by construction and read more cleanly at the call
//! site.

use core::cell::UnsafeCell;

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
/// A single `with_mut`-style API for both scalars and buffers invites
/// `X.with_mut(|x| { *x = X.get() + 1 })` — the read-snapshot-mutate-
/// writeback shape that silently miscompiles in release. By keeping
/// scalars on `get`/`set` and buffers on a separate [`PersistBuf`] type,
/// calling `with_mut` on a `Persist` becomes a "method not found"
/// compile error, not a runtime hazard:
///
/// ```compile_fail
/// use conjuredsp::Persist;
/// static X: Persist<f64> = Persist::new(0.0);
/// X.with_mut(|v| *v = 1.0);  // E0599: method `with_mut` not found
/// ```
pub struct Persist<T: Copy>(UnsafeCell<T>);

// SAFETY: WASM modules are single-threaded; the host never calls
// `process()` reentrantly on the same instance.
unsafe impl<T: Copy> Sync for Persist<T> {}

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

/// Persistent buffer (typically a large array or struct) with in-place
/// mutation via [`with_mut`](PersistBuf::with_mut).
///
/// Choose this over [`Persist<T>`] when the value is large enough that
/// `get`/`set` round-trips would materially regress performance — the
/// 384 KB stereo delay buffer, multi-MB reverb networks, ring-buffer
/// scratch.
///
/// # Reentrancy contract
///
/// `with_mut` borrows the wrapped value mutably for the closure's
/// lifetime. The closure must not call any other method on the same
/// `PersistBuf` — aliased `&mut T` is undefined behaviour even on a
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
/// persist_buf!(DELAY_BUF: [[f32; 48_000]; 2] = [[0.0; 48_000]; 2]);
///
/// // Inside process():
/// DELAY_BUF.with_mut(|buf| {
///     buf[channel][write_pos] = sample;
/// });
/// ```
pub struct PersistBuf<T> {
    inner: UnsafeCell<T>,
    #[cfg(debug_assertions)]
    in_use: core::cell::Cell<bool>,
}

// SAFETY: WASM modules are single-threaded; the host never calls
// `process()` reentrantly on the same instance.
unsafe impl<T> Sync for PersistBuf<T> {}

impl<T> PersistBuf<T> {
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
    /// `f` MUST NOT call any other method on the same `PersistBuf`.
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
                "reentrant PersistBuf::with_mut"
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
