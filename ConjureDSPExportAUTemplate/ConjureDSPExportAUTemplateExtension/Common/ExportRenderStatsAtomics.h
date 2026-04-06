//
//  ExportRenderStatsAtomics.h
//  ConjureDSPExportAUTemplateExtension
//
//  C atomic counters used by RenderStats. Lives in a C header so Swift can
//  perform lock-free atomic ops on the audio thread without depending on
//  Swift's Synchronization module (which has evolving language-mode
//  requirements). All functions are static inline so they are inlined into
//  the calling Swift code with no function-call overhead.
//

#ifndef EXPORT_RENDER_STATS_ATOMICS_H
#define EXPORT_RENDER_STATS_ATOMICS_H

#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

typedef struct {
    _Atomic uint64_t renderCallCount;
    _Atomic uint64_t totalFrames;
    _Atomic uint64_t lastFrameCount;
    _Atomic uint64_t lastRenderDurationNs;
    _Atomic uint64_t peakRenderDurationNs;
    _Atomic uint64_t dropoutCount;
} ExportRenderStatsAtomics;

/// Plain-value copy of the atomic fields, returned by a snapshot.
typedef struct {
    uint64_t renderCallCount;
    uint64_t totalFrames;
    uint64_t lastFrameCount;
    uint64_t lastRenderDurationNs;
    uint64_t peakRenderDurationNs;
    uint64_t dropoutCount;
} ExportRenderStatsValues;

/// Allocate and zero-initialize a new atomics block.
static inline ExportRenderStatsAtomics *export_render_stats_create(void) {
    return (ExportRenderStatsAtomics *)calloc(1, sizeof(ExportRenderStatsAtomics));
}

/// Free a block returned by export_render_stats_create().
static inline void export_render_stats_destroy(ExportRenderStatsAtomics *s) {
    free(s);
}

/// Reset all counters to zero. Main-thread only (no guarantees for concurrent readers).
static inline void export_render_stats_reset(ExportRenderStatsAtomics *s) {
    atomic_store_explicit(&s->renderCallCount, 0, memory_order_relaxed);
    atomic_store_explicit(&s->totalFrames, 0, memory_order_relaxed);
    atomic_store_explicit(&s->lastFrameCount, 0, memory_order_relaxed);
    atomic_store_explicit(&s->lastRenderDurationNs, 0, memory_order_relaxed);
    atomic_store_explicit(&s->peakRenderDurationNs, 0, memory_order_relaxed);
    atomic_store_explicit(&s->dropoutCount, 0, memory_order_relaxed);
}

/// Record one render-block invocation. Audio-thread safe — performs only
/// relaxed atomic stores plus a CAS loop for the peak duration.
static inline void export_render_stats_record(ExportRenderStatsAtomics *s,
                                              uint64_t frames,
                                              uint64_t durationNs,
                                              bool dropout) {
    atomic_fetch_add_explicit(&s->renderCallCount, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&s->totalFrames, frames, memory_order_relaxed);
    atomic_store_explicit(&s->lastFrameCount, frames, memory_order_relaxed);
    atomic_store_explicit(&s->lastRenderDurationNs, durationNs, memory_order_relaxed);
    uint64_t peak = atomic_load_explicit(&s->peakRenderDurationNs, memory_order_relaxed);
    while (durationNs > peak) {
        if (atomic_compare_exchange_weak_explicit(&s->peakRenderDurationNs,
                                                  &peak,
                                                  durationNs,
                                                  memory_order_relaxed,
                                                  memory_order_relaxed)) {
            break;
        }
    }
    if (dropout) {
        atomic_fetch_add_explicit(&s->dropoutCount, 1, memory_order_relaxed);
    }
}

/// Relaxed-load snapshot of all fields into a plain struct.
/// Individual field reads are atomic; the snapshot as a whole is not
/// instantaneous — but relaxed reads of counters-only data are fine for
/// human-readable UI display.
static inline void export_render_stats_snapshot(const ExportRenderStatsAtomics *s,
                                                ExportRenderStatsValues *out) {
    out->renderCallCount = atomic_load_explicit(&s->renderCallCount, memory_order_relaxed);
    out->totalFrames = atomic_load_explicit(&s->totalFrames, memory_order_relaxed);
    out->lastFrameCount = atomic_load_explicit(&s->lastFrameCount, memory_order_relaxed);
    out->lastRenderDurationNs = atomic_load_explicit(&s->lastRenderDurationNs, memory_order_relaxed);
    out->peakRenderDurationNs = atomic_load_explicit(&s->peakRenderDurationNs, memory_order_relaxed);
    out->dropoutCount = atomic_load_explicit(&s->dropoutCount, memory_order_relaxed);
}

/// Reset only the peak render duration counter. Main-thread only.
static inline void export_render_stats_reset_peak(ExportRenderStatsAtomics *s) {
    atomic_store_explicit(&s->peakRenderDurationNs, 0, memory_order_relaxed);
}

#endif
