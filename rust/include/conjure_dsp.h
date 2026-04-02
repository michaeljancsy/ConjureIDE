#ifndef CONJURE_DSP_H
#define CONJURE_DSP_H

#include <stdint.h>
#include <stdbool.h>

/**
 * Maximum number of parameters exposed to the DAW.
 */
#define PARAM_COUNT 16

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
 * `(input_ptr: i32, output_ptr: i32, channels: i32, frame_count: i32, sample_rate: f32)`
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
 * Returns the NAM model path embedded in the loaded WASM module, or null if none.
 * The returned pointer is valid until the next `load_wasm` or `dsp_kernel_destroy`.
 *
 * # Safety
 * - `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 */
const char *dsp_kernel_nam_path(DSPKernelRef kernel);

/**
 * Inject NAM model binary data into the loaded WASM backend.
 * Call after `dsp_kernel_load_wasm` when `dsp_kernel_nam_path` returns non-null.
 * Returns true on success.
 *
 * # Safety
 * - `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 * - `data` must point to `len` valid bytes.
 */
bool dsp_kernel_inject_nam(DSPKernelRef kernel, const uint8_t *data, uintptr_t len);

/**
 * Benchmark the process function.
 * Returns the max execution time in seconds over 5 runs, or -1.0 if no script is loaded.
 *
 * # Safety
 * `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 */
double dsp_kernel_benchmark_process(DSPKernelRef kernel);

/**
 * Returns the last error message as a null-terminated C string.
 * Returns null if no error. The pointer is valid until the next call to this function or destroy.
 *
 * # Safety
 * `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 */
const char *dsp_kernel_last_error(DSPKernelRef kernel);

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

#endif  /* CONJURE_DSP_H */
