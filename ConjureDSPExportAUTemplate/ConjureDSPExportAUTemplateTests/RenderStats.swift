//
//  RenderStats.swift
//  ConjureDSPExportAUTemplateTests
//
//  Copy of RenderStats from ConjureDSPExportAUTemplateExtension for unit
//  testing. The AU extension target can't be @testable-imported because
//  it's an appex, so the test target compiles its own copy.
//

import Darwin.Mach
import Foundation

final class RenderStats: @unchecked Sendable {
    /// Plain-value snapshot of the atomic counters plus derived values.
    struct Snapshot: Sendable {
        var renderCallCount: UInt64
        var totalFrames: UInt64
        var lastFrameCount: UInt64
        var lastRenderDurationNs: UInt64
        var peakRenderDurationNs: UInt64
        var dropoutCount: UInt64
        /// Render-block calls per second since the previous snapshot.
        var callsPerSecond: Double
        /// Sample rate the AU is running at, or 0 if unknown.
        var sampleRate: Double

        static let empty = Snapshot(
            renderCallCount: 0,
            totalFrames: 0,
            lastFrameCount: 0,
            lastRenderDurationNs: 0,
            peakRenderDurationNs: 0,
            dropoutCount: 0,
            callsPerSecond: 0,
            sampleRate: 0
        )

        /// Estimated CPU % of the last render block, based on wall-clock ratio
        /// of render duration to the audio time represented by the frames.
        /// Returns 0 when sample rate or frame count is unknown.
        var lastCpuPercent: Double {
            guard sampleRate > 0, lastFrameCount > 0 else { return 0 }
            let budgetNs = Double(lastFrameCount) * 1_000_000_000.0 / sampleRate
            guard budgetNs > 0 else { return 0 }
            return Double(lastRenderDurationNs) / budgetNs * 100.0
        }

        /// Estimated peak CPU %, based on peak render duration against the
        /// most recent frame count / sample rate.
        var peakCpuPercent: Double {
            guard sampleRate > 0, lastFrameCount > 0 else { return 0 }
            let budgetNs = Double(lastFrameCount) * 1_000_000_000.0 / sampleRate
            guard budgetNs > 0 else { return 0 }
            return Double(peakRenderDurationNs) / budgetNs * 100.0
        }
    }

    // MARK: - Audio-thread-owned fields

    private let atomicsPtr: UnsafeMutablePointer<ExportRenderStatsAtomics>

    /// Cached mach timebase. Immutable after init — safe to read from the
    /// audio thread.
    private let timebaseNumer: UInt64
    private let timebaseDenom: UInt64

    // MARK: - Main-thread-owned fields

    /// Sample rate the AU is running at. Written on the main thread from
    /// allocateRenderResources, read from snapshot() on main. Not accessed
    /// from the audio thread.
    var sampleRate: Double = 0

    private var lastSnapshotMonoTime: TimeInterval = 0
    private var lastSnapshotCallCount: UInt64 = 0

    init() {
        guard let ptr = export_render_stats_create() else {
            fatalError("RenderStats: calloc failed")
        }
        self.atomicsPtr = ptr

        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        self.timebaseNumer = UInt64(tb.numer)
        self.timebaseDenom = UInt64(tb.denom == 0 ? 1 : tb.denom)
    }

    deinit {
        export_render_stats_destroy(atomicsPtr)
    }

    // MARK: - Audio-thread API

    /// Record one render-block invocation. AUDIO-THREAD SAFE.
    /// No allocations, no locks, no Swift closures — only integer math and
    /// lock-free atomic ops (via the inlined C helpers).
    func recordRender(startMachTime: UInt64, endMachTime: UInt64, frames: UInt64, dropout: Bool) {
        let ticks = endMachTime &- startMachTime
        let ns = ticks &* timebaseNumer / timebaseDenom
        export_render_stats_record(atomicsPtr, frames, ns, dropout)
    }

    // MARK: - Main-thread API

    /// Capture a snapshot of the current counters with calls-per-second derived
    /// against the previous snapshot. Main-thread only.
    func snapshot() -> Snapshot {
        var values = ExportRenderStatsValues(
            renderCallCount: 0,
            totalFrames: 0,
            lastFrameCount: 0,
            lastRenderDurationNs: 0,
            peakRenderDurationNs: 0,
            dropoutCount: 0
        )
        export_render_stats_snapshot(atomicsPtr, &values)

        let now = ProcessInfo.processInfo.systemUptime
        let callsPerSecond: Double
        if lastSnapshotMonoTime > 0 {
            let dt = now - lastSnapshotMonoTime
            let dCalls = values.renderCallCount &- lastSnapshotCallCount
            callsPerSecond = dt > 0 ? Double(dCalls) / dt : 0
        } else {
            callsPerSecond = 0
        }
        lastSnapshotMonoTime = now
        lastSnapshotCallCount = values.renderCallCount

        return Snapshot(
            renderCallCount: values.renderCallCount,
            totalFrames: values.totalFrames,
            lastFrameCount: values.lastFrameCount,
            lastRenderDurationNs: values.lastRenderDurationNs,
            peakRenderDurationNs: values.peakRenderDurationNs,
            dropoutCount: values.dropoutCount,
            callsPerSecond: callsPerSecond,
            sampleRate: sampleRate
        )
    }

    /// Reset only the peak render duration counter. Main-thread only.
    func resetPeak() {
        export_render_stats_reset_peak(atomicsPtr)
    }

    /// Reset all counters. Main-thread only.
    func resetAll() {
        export_render_stats_reset(atomicsPtr)
        lastSnapshotCallCount = 0
        lastSnapshotMonoTime = 0
    }
}
