#ifndef CONJURE_DSP_H
#define CONJURE_DSP_H

#include <stdint.h>
#include <stdbool.h>

/**
 * Default per-script cap for the JSON state buffer (64 KiB). Scripts can
 * raise this via `state!(T, max_bytes = N)` (Rust) — Python presets pin
 * the same default but currently have no opt-in syntax. Audio-thread
 * deserialize cost scales linearly with buffer size, so the default keeps
 * per-block parse time well under 100 µs even on slower hardware.
 */
#define DEFAULT_STATE_CAP_BYTES 65536

/**
 * Hard upper bound on the per-script cap. Going past 1 MiB risks
 * non-trivial audio-thread parse latency on every state mutation.
 */
#define MAX_STATE_CAP_BYTES 1048576

/**
 * Maximum number of parameters exposed to the DAW.
 */
#define PARAM_COUNT 16

/**
 * Maximum number of telemetry slots a script can publish per render
 * block. Telemetry is the read-back twin of params: scripts write
 * internal DSP state (envelope follower, computed GR, sidechain RMS)
 * once per block and the host UI reads the snapshot via
 * `audio.onFrame`'s `telemetry` field. Mirrors `conjuredsp::TELEMETRY_LEN`
 * in the author crate.
 */
#define TELEMETRY_LEN 16

/**
 * Default capacity: 8192 samples (~185ms at 44.1kHz).
 * Enough for multiple FFT windows with overlap.
 */
#define AudioRingBuffer_DEFAULT_CAPACITY 8192

/**
 * Real-time audio DSP kernel with pluggable processing backends.
 *
 * Supports Python scripts (via pyo3/numpy) and WASM modules (via wasmtime).
 * When a backend is loaded, `process()` delegates to it. When no backend
 * is loaded or the backend errors, the kernel falls back to passthrough.
 *
 * Thread safety: The `backend` field is wrapped in a `Mutex` to prevent
 * use-after-free when the main thread swaps backends while the render thread
 * is processing. The render thread uses `try_lock()` (never blocks — falls
 * back to passthrough if the lock is held during a swap).
 */
typedef struct DSPKernel DSPKernel;

/**
 * Opaque handle to the DSP kernel. Swift sees this as `OpaquePointer`.
 */
typedef struct DSPKernel *DSPKernelRef;

DSPKernelRef dsp_kernel_create(void);

/**
 * # Safety
 * `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 */
void dsp_kernel_destroy(DSPKernelRef kernel);

/**
 * # Safety
 * `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 */
void dsp_kernel_initialize(DSPKernelRef kernel,
                           int32_t input_channel_count,
                           int32_t output_channel_count,
                           double sample_rate);

/**
 * # Safety
 * `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 */
void dsp_kernel_deinitialize(DSPKernelRef kernel);

/**
 * # Safety
 * `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 */
void dsp_kernel_set_bypassed(DSPKernelRef kernel, bool bypass);

/**
 * Mark the start of a preset-load window. The audio thread ramps the output
 * to silence (5 ms fade-out) and holds silence — even after a backend swap —
 * until `dsp_kernel_end_preset_transition` is called. Idempotent.
 *
 * Wrap every code path that mutates kernel parameters or stages a new backend
 * (`selectPreset`, `currentPreset` setter, MCP `save_preset`, `fullState`
 * restore, etc.) so the OLD backend can't be heard rendering audio with the
 * NEW preset's parameter values during the load window.
 *
 * # Safety
 * `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 */
void dsp_kernel_begin_preset_transition(DSPKernelRef kernel);

/**
 * Release the mute hold set by `dsp_kernel_begin_preset_transition`. The
 * audio thread observes the cleared flag on its next callback and ramps the
 * output back to full level via FADE_IN. Idempotent.
 *
 * # Safety
 * `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 */
void dsp_kernel_end_preset_transition(DSPKernelRef kernel);

/**
 * Returns the current swap-state-machine phase
 * (0 = IDLE, 1 = FADE_OUT, 2 = FADE_IN). Diagnostic only — used by tests
 * to verify the kernel returned to IDLE after a preset transition.
 *
 * # Safety
 * `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 */
uint8_t dsp_kernel_swap_phase(DSPKernelRef kernel);

/**
 * # Safety
 * `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 */
bool dsp_kernel_is_bypassed(DSPKernelRef kernel);

/**
 * # Safety
 * `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 */
void dsp_kernel_set_parameter(DSPKernelRef kernel, uint64_t address, float value);

/**
 * # Safety
 * `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 */
float dsp_kernel_get_parameter(DSPKernelRef kernel, uint64_t address);

/**
 * # Safety
 * `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 */
uint32_t dsp_kernel_get_max_frames(DSPKernelRef kernel);

/**
 * # Safety
 * `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 */
void dsp_kernel_set_max_frames(DSPKernelRef kernel, uint32_t max_frames);

/**
 * Process audio buffers. Called from the real-time audio thread.
 *
 * # Safety
 * - `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 * - `input_buffers` must point to `channel_count` valid `*const f32` pointers.
 * - `output_buffers` must point to `channel_count` valid `*mut f32` pointers.
 * - Each channel buffer must contain at least `frame_count` samples.
 */
void dsp_kernel_process(DSPKernelRef kernel,
                        const float *const *input_buffers,
                        float *const *output_buffers,
                        uint32_t channel_count,
                        uint32_t frame_count);

/**
 * Process audio with an optional sidechain input bus. Mirrors
 * `dsp_kernel_process` and adds three trailing arguments describing the
 * sidechain pull for this render block.
 *
 * When `sidechain_connected` is false (or `sidechain_buffers` is null,
 * or `sidechain_channel_count` is zero), backends that consume sidechain
 * audio see silence. Old presets that don't read sidechain are
 * unaffected.
 *
 * Both sides of the FFI ship together, so this is purely additive — the
 * legacy `dsp_kernel_process` entry point delegates to this one with no
 * sidechain so callers that haven't been updated still work.
 *
 * # Safety
 * - `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 * - `input_buffers` / `output_buffers` constraints from `dsp_kernel_process`
 *   apply.
 * - When `sidechain_connected` is true and `sidechain_buffers` is non-null,
 *   it must point to `sidechain_channel_count` valid `*const f32` pointers,
 *   each with at least `frame_count` samples.
 */
void dsp_kernel_process_with_sidechain(DSPKernelRef kernel,
                                       const float *const *input_buffers,
                                       float *const *output_buffers,
                                       uint32_t channel_count,
                                       uint32_t frame_count,
                                       const float *const *sidechain_buffers,
                                       uint32_t sidechain_channel_count,
                                       bool sidechain_connected);

/**
 * Update host DAW transport state. Called from the real-time audio thread
 * once per render callback, before the process loop.
 *
 * # Safety
 * - `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 */
void dsp_kernel_set_transport(DSPKernelRef kernel,
                              double tempo,
                              double beat_position,
                              bool is_playing,
                              int32_t time_sig_numerator,
                              int32_t time_sig_denominator,
                              double sample_position);

/**
 * Load a Python script for DSP processing.
 *
 * `python_home` is the path to the bundled Python distribution root (containing lib/python3.14/).
 * `script_path` is the path to the .py file containing a `process()` function.
 *
 * Returns true on success, false on error (errors are printed to stderr).
 *
 * # Safety
 * - `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 * - `python_home` and `script_path` must be valid null-terminated C strings.
 */
bool dsp_kernel_load_script(DSPKernelRef kernel, const char *python_home, const char *script_path);

/**
 * Prepend a directory to Python's sys.path so user-installed packages are importable.
 * Idempotent — safe to call multiple times. Takes effect immediately.
 * Pass null to no-op.
 *
 * # Safety
 * - `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 * - `path` must be a valid null-terminated C string, or null.
 */
void dsp_kernel_set_extra_site_packages(DSPKernelRef kernel, const char *path);

/**
 * Set the directory where downloaded NAM tone files are stored.
 * This sets the `CONJUREDSP_TONES_DIR` environment variable so Python scripts
 * can resolve `tone3000://` paths via `conjuredsp.nam.load_model()`.
 *
 * Call this once after kernel creation, before loading scripts.
 * Pass null to no-op.
 *
 * # Safety
 * - `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 * - `path` must be a valid null-terminated C string, or null.
 */
void dsp_kernel_set_tones_dir(DSPKernelRef _kernel, const char *path);

/**
 * Load a WASM module for DSP processing.
 *
 * The module must export a `process` function with signature
 * `(input_ptr: i32, output_ptr: i32, channel_count: i32, frame_count: i32, sample_rate: f32)`
 * and a `memory` (linear memory).
 *
 * Returns true on success, false on error (check `dsp_kernel_last_error`).
 *
 * # Safety
 * - `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 * - `wasm_bytes` must point to `len` valid bytes of a WASM module.
 */
bool dsp_kernel_load_wasm(DSPKernelRef kernel, const uint8_t *wasm_bytes, uint32_t len);

/**
 * Returns the number of NAM model slots declared by the loaded WASM module.
 * 0 when the module declares no NAM models.
 *
 * # Safety
 * - `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 */
uint32_t dsp_kernel_nam_path_count(DSPKernelRef kernel);

/**
 * Returns the NAM model path declared at slot `idx`, or null if `idx` is out of range.
 * The returned pointer is valid until the next `load_wasm`, `dsp_kernel_destroy`, or
 * next call to this function.
 *
 * # Safety
 * - `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 */
const char *dsp_kernel_nam_path_at(DSPKernelRef kernel, uint32_t idx);

/**
 * Inject NAM model binary data into the loaded WASM backend at the given slot.
 * Call after `dsp_kernel_load_wasm` for each path returned by `dsp_kernel_nam_path_at`.
 * Returns true on success.
 *
 * # Safety
 * - `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 * - `data` must point to `len` valid bytes.
 */
bool dsp_kernel_inject_nam_slot(DSPKernelRef kernel,
                                uint32_t slot,
                                const uint8_t *data,
                                uintptr_t len);

/**
 * Benchmark the process function.
 * Returns the max execution time in seconds over 5 runs, or -1.0 if no script is loaded.
 *
 * # Safety
 * `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 */
double dsp_kernel_benchmark_process(DSPKernelRef kernel);

/**
 * Monotonic counter that bumps on every state change to the kernel's
 * `last_error` (None → Some, Some → None, Some(x) → Some(y), and the
 * initial set). Swift polls this on a timer; only when it advances does
 * it re-read `dsp_kernel_last_error`. Lets the editor surface runtime
 * errors as Monaco markers without scanning the error string on every
 * poll.
 *
 * # Safety
 * `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 */
uint64_t dsp_kernel_error_generation(DSPKernelRef kernel);

/**
 * Returns the last error message as a null-terminated C string.
 * Returns null if no error. The pointer is valid until the next call to this function or destroy.
 *
 * # Safety
 * `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 */
const char *dsp_kernel_last_error(DSPKernelRef kernel);

/**
 * Atomic variant of `dsp_kernel_last_error` + `dsp_kernel_error_generation`.
 * Writes the current `error_generation` into `*out_generation` AND returns
 * the last error string (or null), with both values produced under the
 * same mutex lock so the pair is coherent. Use this when you've taken a
 * baseline `error_generation` and want to detect "did the kernel
 * transition to a new error since baseline?" without racing the audio
 * thread between the gen-read and string-read.
 *
 * Same thread-local CString contract as `dsp_kernel_last_error`: the
 * returned pointer is valid until the next call to either function on
 * this thread or until `dsp_kernel_destroy`.
 *
 * # Safety
 * `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 * `out_generation` must be a valid `*mut u64` (may not be null).
 */
const char *dsp_kernel_last_error_with_generation(DSPKernelRef kernel, uint64_t *out_generation);

/**
 * Returns script-declared parameter names as a null-terminated JSON C string,
 * e.g. `{"0":"Cutoff","1":"Resonance"}`.
 * Returns null if the loaded script does not declare parameter names.
 * The pointer is valid until the next script load or kernel destroy.
 *
 * # Safety
 * `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 */
const char *dsp_kernel_param_names_json(DSPKernelRef kernel);

/**
 * Returns rich parameter metadata as a null-terminated JSON array string,
 * e.g. `[{"name":"Threshold","min":-40,"max":-3,"unit":"dB","default":-20}, ...]`.
 * Returns null if the loaded script does not declare a `PARAMS` dict.
 * The pointer is valid until the next script load or kernel destroy.
 *
 * # Safety
 * `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 */
const char *dsp_kernel_param_metadata_json(DSPKernelRef kernel);

/**
 * Returns the script-declared algorithmic latency in samples.
 * Zero means no latency. Used by the AU host to report
 * `AUAudioUnit.latency` for DAW delay compensation.
 *
 * # Safety
 * `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 */
uint32_t dsp_kernel_latency_samples(DSPKernelRef kernel);

/**
 * Returns a pointer to the cached telemetry slot metadata JSON
 * (`[{name, key?, unit}, …]`), or null when the script declared no
 * telemetry. Pointer is valid until the next script load or kernel
 * destroy; Swift caches the parsed slot names.
 *
 * Telemetry is the read-back twin of `dsp_kernel_param_metadata_json`:
 * scripts publish internal DSP state per render block via
 * `Context::set_telemetry_scalar` / `TELEMETRY` dict, host UI reads
 * the snapshot via `dsp_kernel_read_telemetry`.
 *
 * # Safety
 * `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 */
const char *dsp_kernel_telemetry_metadata_json(DSPKernelRef kernel);

/**
 * Snapshot the latest telemetry values published by the most recent
 * `process()` call into the caller's buffer. Writes up to `max`
 * slots (capped at the kernel's TELEMETRY_LEN, currently 16) and
 * returns the number written. Lock-free Relaxed read of per-slot
 * atomics; safe to call from any thread, throttled in practice to
 * display-link cadence (~30–120 Hz).
 *
 * # Safety
 * - `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 * - `out` must point to at least `max` writable f32 values.
 */
uint32_t dsp_kernel_read_telemetry(DSPKernelRef kernel, float *out, uint32_t max);

/**
 * Snapshot the latest per-frame values written by the most recent
 * `process()` call for the vector telemetry slot at metadata position
 * `slot_index`. Writes up to `max` f32 values into `out` and returns
 * the number actually written. Returns 0 when the slot is scalar /
 * not declared / has not been written yet, or when the script is on
 * a backend that doesn't support vector telemetry.
 *
 * Brief lock under the hood (see `DSPKernel::read_telemetry_vec`);
 * safe to call from the UI / display-link thread at ~30–120 Hz.
 *
 * # Safety
 * - `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 * - `out` must point to at least `max` writable f32 values.
 */
uint32_t dsp_kernel_read_telemetry_vec(DSPKernelRef kernel,
                                       uint32_t slot_index,
                                       float *out,
                                       uint32_t max);

/**
 * Enable or disable audio capture for spectrogram visualization.
 * When disabled, ring buffers are not written to (saves CPU on audio thread).
 *
 * # Safety
 * `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 */
void dsp_kernel_set_capture_enabled(DSPKernelRef kernel, bool enabled);

/**
 * Read available samples from the input (pre-processing) ring buffer.
 * Returns the number of samples actually read (up to `max_samples`).
 * Called from the UI thread only.
 *
 * # Safety
 * - `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 * - `out` must point to at least `max_samples` writable f32 values.
 */
uint32_t dsp_kernel_read_input_ring(DSPKernelRef kernel, float *out, uint32_t max_samples);

/**
 * Read available samples from the output (post-processing) ring buffer.
 * Returns the number of samples actually read (up to `max_samples`).
 * Called from the UI thread only.
 *
 * # Safety
 * - `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 * - `out` must point to at least `max_samples` writable f32 values.
 */
uint32_t dsp_kernel_read_output_ring(DSPKernelRef kernel, float *out, uint32_t max_samples);

/**
 * Verify a subscription token's signature and expiry, then set the kernel's
 * subscription status and licensed flag.
 *
 * Returns a `SubscriptionStatus` value (0=Active, 1=GracePeriod, 2=Expired,
 * 3=Cancelled, 4=NoSubscription).
 *
 * # Safety
 * - `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 * - `token` must be a valid null-terminated C string.
 */
uint8_t dsp_kernel_verify_token(DSPKernelRef kernel, const char *token);

/**
 * Check if the kernel has a valid license.
 *
 * # Safety
 * `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 */
bool dsp_kernel_is_licensed(DSPKernelRef kernel);

/**
 * Get the remaining demo time in seconds at the given sample rate.
 * Returns infinity if licensed.
 *
 * # Safety
 * `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 */
double dsp_kernel_demo_seconds_remaining(DSPKernelRef kernel, double sample_rate);

/**
 * Set the subscription status directly (for restoring from cached token
 * or when the Swift layer determines the status via server call).
 *
 * Status values: 0=Active, 1=GracePeriod, 2=Expired, 3=Cancelled, 4=NoSubscription
 *
 * # Safety
 * `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 */
void dsp_kernel_set_subscription_status(DSPKernelRef kernel, uint8_t status);

/**
 * Get the current subscription status.
 *
 * Returns: 0=Active, 1=GracePeriod, 2=Expired, 3=Cancelled, 4=NoSubscription
 *
 * # Safety
 * `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 */
uint8_t dsp_kernel_subscription_status(DSPKernelRef kernel);

/**
 * Get the grace period deadline as Unix seconds.
 * Returns 0 if no token has been verified.
 *
 * # Safety
 * `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 */
int64_t dsp_kernel_grace_deadline_unix(DSPKernelRef kernel);

/**
 * Set the licensed state directly (for restoring from persisted license).
 *
 * # Safety
 * `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 */
void dsp_kernel_set_licensed(DSPKernelRef kernel, bool licensed);

/**
 * Reset the demo sample counter, giving another 60 seconds of demo time.
 *
 * # Safety
 * `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 */
void dsp_kernel_reset_demo(DSPKernelRef kernel);

/**
 * Return a pointer to the embedded Ed25519 public key (32 bytes).
 * Only available in debug builds for diagnostics. Returns null in release.
 */
const uint8_t *dsp_kernel_public_key(void);

/**
 * Get the most recent backend.process() duration in microseconds.
 * Returns 0 when no backend has processed yet.
 *
 * # Safety
 * `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 */
uint32_t dsp_kernel_profiler_current_us(DSPKernelRef kernel);

/**
 * Get the exponential moving average of backend.process() duration in microseconds.
 * Smoothed over ~0.5 seconds of callbacks.
 *
 * # Safety
 * `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 */
uint32_t dsp_kernel_profiler_avg_us(DSPKernelRef kernel);

/**
 * Get the decaying peak of backend.process() duration in microseconds.
 * Decays by ~0.1% per callback, so peaks fade after a few seconds.
 *
 * # Safety
 * `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 */
uint32_t dsp_kernel_profiler_peak_us(DSPKernelRef kernel);

/**
 * Get the current process resident memory in bytes via mach task_info.
 * Does not require a kernel — measures process-wide RSS.
 * Returns 0 on failure. Safe to call from any thread (~1µs).
 */
uint64_t dsp_kernel_process_resident_bytes(void);

/**
 * Get the process RSS baseline recorded when the current script was loaded.
 *
 * # Safety
 * `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 */
uint64_t dsp_kernel_memory_baseline_bytes(DSPKernelRef kernel);

/**
 * Get the current WASM linear memory size in bytes.
 * Returns 0 if the current backend is not WASM.
 *
 * # Safety
 * `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 */
uint64_t dsp_kernel_wasm_memory_bytes(DSPKernelRef kernel);

/**
 * Get the actual frame count from the most recent render callback.
 * Returns 0 before the first render call. Use this instead of
 * `dsp_kernel_get_max_frames` to display the true audio budget, since
 * DAW buffer sizes below the AU framework minimum (64) are clamped in
 * `maximumFramesToRender` but still arrive as smaller `frameCount` values
 * in the render block.
 *
 * # Safety
 * `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 */
uint32_t dsp_kernel_last_render_frame_count(DSPKernelRef kernel);

/**
 * Set the per-script cap on the state buffer in bytes. Called by Swift
 * at script load (passes the script's declared `max_bytes` from
 * `state!(T, max_bytes = N)` in Rust, or the default 64 KiB for Python
 * presets which currently have no opt-in syntax). Subsequent
 * `dsp_kernel_set_state_json` calls reject inputs over this size.
 *
 * # Safety
 * `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 */
void dsp_kernel_set_state_cap(DSPKernelRef kernel, uintptr_t max_bytes);

/**
 * Returns the currently configured state cap in bytes.
 *
 * # Safety
 * `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 */
uintptr_t dsp_kernel_state_cap(DSPKernelRef kernel);

/**
 * Try to install a new state buffer. Validates that the bytes are
 * well-formed JSON and within the per-script cap. Returns `true` on
 * success, `false` on rejection. On failure the existing buffer +
 * generation are unchanged.
 *
 * # Safety
 * - `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 * - `bytes` must be a valid pointer to `len` bytes (or null when len==0).
 */
bool dsp_kernel_set_state_json(DSPKernelRef kernel, const uint8_t *bytes, uintptr_t len);

/**
 * Copy the current state buffer into the caller-provided buffer.
 * Writes up to `max_len` bytes and returns the actual length the kernel
 * wanted to write (so callers can detect truncation). Pass `out=null,
 * max_len=0` to query length only.
 *
 * # Safety
 * - `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 * - When `max_len > 0`, `out` must be valid for `max_len` bytes.
 */
uintptr_t dsp_kernel_get_state_json(DSPKernelRef kernel, uint8_t *out, uintptr_t max_len);

/**
 * Read the current state generation counter without taking the buffer.
 * Used by the smoke tester to verify that a UI write actually landed.
 *
 * # Safety
 * `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 */
uint64_t dsp_kernel_state_generation(DSPKernelRef kernel);

/**
 * Returns a pointer to the most recently loaded backend's STATE
 * defaults JSON, or null when none was declared (Python-only
 * concept — WASM gets defaults from its `Default` impl). Pointer is
 * valid until the next script load or kernel destroy.
 *
 * # Safety
 * `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 */
const char *dsp_kernel_state_defaults_json(DSPKernelRef kernel);

/**
 * C = A * B where A is m×k, B is k×n, C is m×n. Stride params are element strides.
 */
extern void vDSP_mmul(const float *a,
                      int32_t a_stride,
                      const float *b,
                      int32_t b_stride,
                      float *c,
                      int32_t c_stride,
                      uint32_t m,
                      uint32_t k,
                      uint32_t n);

/**
 * C[i] = A[i] + B[i]
 */
extern void vDSP_vadd(const float *a,
                      int32_t a_stride,
                      const float *b,
                      int32_t b_stride,
                      float *c,
                      int32_t c_stride,
                      uint32_t n);

/**
 * C[i] = A[i] * B[i]
 */
extern void vDSP_vmul(const float *a,
                      int32_t a_stride,
                      const float *b,
                      int32_t b_stride,
                      float *c,
                      int32_t c_stride,
                      uint32_t n);

/**
 * C[i] = A[i] + *B (add scalar)
 */
extern void vDSP_vsadd(const float *a,
                       int32_t a_stride,
                       const float *b,
                       float *c,
                       int32_t c_stride,
                       uint32_t n);

/**
 * y[i] = tanh(x[i])
 */
extern void vvtanhf(float *y, const float *x, const int32_t *n);

/**
 * y[i] = exp(x[i])
 */
extern void vvexpf(float *y, const float *x, const int32_t *n);

/**
 * C[i] = -A[i]
 */
extern void vDSP_vneg(const float *a, int32_t a_stride, float *c, int32_t c_stride, uint32_t n);

/**
 * C[i] = *A / B[i]
 */
extern void vDSP_svdiv(const float *a,
                       const float *b,
                       int32_t b_stride,
                       float *c,
                       int32_t c_stride,
                       uint32_t n);

/**
 * BLAS general matrix multiply: C = alpha*A*B + beta*C
 * order: 101=RowMajor, transA/transB: 111=NoTrans
 */
extern void cblas_sgemm(int32_t order,
                        int32_t trans_a,
                        int32_t trans_b,
                        int32_t m,
                        int32_t n,
                        int32_t k,
                        float alpha,
                        const float *a,
                        int32_t lda,
                        const float *b,
                        int32_t ldb,
                        float beta,
                        float *c,
                        int32_t ldc);

#endif  /* CONJURE_DSP_H */
