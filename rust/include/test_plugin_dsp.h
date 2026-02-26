#ifndef TEST_PLUGIN_DSP_H
#define TEST_PLUGIN_DSP_H

#include <stdint.h>
#include <stdbool.h>

/**
 * Parameter addresses — must match the Swift enum in Parameters.swift.
 */
#define PARAM_GAIN 0

/**
 * Real-time audio DSP kernel.
 *
 * All methods are safe for the audio render thread:
 * no allocations, no locks, no syscalls.
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

#endif  /* TEST_PLUGIN_DSP_H */
