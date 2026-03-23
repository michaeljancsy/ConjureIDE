#ifndef BEARBONE_DSP_H
#define BEARBONE_DSP_H

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
 * Verify a license serial key and set the kernel's licensed state.
 * Returns true if the license is valid.
 *
 * # Safety
 * - `kernel` must be a valid pointer returned by `dsp_kernel_create`.
 * - `serial` must be a valid null-terminated C string.
 */
bool dsp_kernel_verify_license(DSPKernelRef kernel, const char *serial);

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
 * The pointer is valid for the lifetime of the process (static data).
 */
const uint8_t *dsp_kernel_public_key(void);

#endif  /* BEARBONE_DSP_H */
