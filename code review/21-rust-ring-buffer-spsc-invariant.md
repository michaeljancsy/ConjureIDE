An AI has found the following issue. Please review and assess whether action is needed.

# Rust: ring buffer's SPSC invariant is unenforced and silently corruptible

## Context
`rust/conjure_dsp/src/ring_buffer.rs` implements a single-producer single-consumer (SPSC) lock-free ring buffer. The audio thread is the producer (writing per-render samples for spectrogram FFT); the UI thread is the consumer.

## Issue
The reviewer flagged (around lines 47–71) that the ring buffer's `write` and `read` methods don't enforce single-producer / single-consumer at the type level. If a future caller invokes `write` from two threads (or `read` from two threads), the head/tail atomics still operate but the resulting state is corrupt — the available-space calculation `available = capacity - (write - read)` underflows silently, producing absurd values that propagate as NaN audio or panics far from the actual misuse.

The issue isn't an active bug — it's that the safety contract is a comment, not a compiler check.

## Location
- `rust/conjure_dsp/src/ring_buffer.rs` — `write`/`read` and the available-space math, ~lines 47–71

## Why it matters
- Defensive: any future change ("let me add a second producer for MIDI events" or similar) silently corrupts audio.
- Hard to debug: by the time NaN appears in the spectrogram output, the offending write site is long gone from the stack.
- A human reviewer would always ask "what enforces SPSC here?" — the answer should be "the type system," not "the comment."

## What to verify
- Read `ring_buffer.rs` end to end.
- Identify all current callers of `write` (should be one — audio thread) and `read` (should be one — UI/spectrogram thread).
- Check the atomic orderings used — Acquire/Release are correct for SPSC, Relaxed is not.

## Suggested approach
- Split into `Producer` and `Consumer` halves at construction:
  ```rust
  let (producer, consumer) = RingBuffer::new(cap);
  ```
  Each is `!Sync` (or wrapped to enforce single ownership). Only the producer has `write`; only the consumer has `read`. Move semantics enforce single ownership.
- Audit atomic orderings — head should be `Release` on write / `Acquire` on read of the same field, and vice versa.
- Add `debug_assert!` on the available-space math to catch underflow in dev builds.
- Consider using an existing crate like `rtrb` or `ringbuf` instead of hand-rolled — both are well-tested and enforce SPSC at the type level.
