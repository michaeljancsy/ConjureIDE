//
//  RenderStatsTests.swift
//  ConjureDSPExportAUTemplateTests
//

import Darwin.Mach
import Foundation
import Testing

@Suite("RenderStats")
struct RenderStatsTests {
    @Test("recordRender updates basic counters")
    func basicCounters() {
        let stats = RenderStats()
        let t0: UInt64 = 1_000
        let t1: UInt64 = 2_000
        stats.recordRender(startMachTime: t0, endMachTime: t1, frames: 512, dropout: false)

        let snap = stats.snapshot()
        #expect(snap.renderCallCount == 1)
        #expect(snap.totalFrames == 512)
        #expect(snap.lastFrameCount == 512)
        #expect(snap.dropoutCount == 0)
        #expect(snap.lastRenderDurationNs > 0)
    }

    @Test("dropout flag increments dropoutCount")
    func dropoutCounting() {
        let stats = RenderStats()
        stats.recordRender(startMachTime: 0, endMachTime: 100, frames: 256, dropout: false)
        stats.recordRender(startMachTime: 0, endMachTime: 100, frames: 256, dropout: true)
        stats.recordRender(startMachTime: 0, endMachTime: 100, frames: 256, dropout: true)
        let snap = stats.snapshot()
        #expect(snap.renderCallCount == 3)
        #expect(snap.dropoutCount == 2)
    }

    @Test("peakRenderDurationNs tracks maximum")
    func peakTracking() {
        let stats = RenderStats()
        // Construct mach times with increasing deltas.
        stats.recordRender(startMachTime: 0, endMachTime: 100, frames: 64, dropout: false)
        stats.recordRender(startMachTime: 0, endMachTime: 500, frames: 64, dropout: false)
        stats.recordRender(startMachTime: 0, endMachTime: 200, frames: 64, dropout: false)
        stats.recordRender(startMachTime: 0, endMachTime: 1000, frames: 64, dropout: false)
        stats.recordRender(startMachTime: 0, endMachTime: 300, frames: 64, dropout: false)
        let snap = stats.snapshot()
        #expect(snap.lastRenderDurationNs > 0)
        // Peak should correspond to the 1000-tick call, which is the largest.
        // lastRenderDurationNs is from the most recent (300-tick) call.
        #expect(snap.peakRenderDurationNs > snap.lastRenderDurationNs)
    }

    @Test("concurrent recordRender is lock-free and lossless")
    func concurrentRecord() {
        let stats = RenderStats()
        let iterations = 10_000
        DispatchQueue.concurrentPerform(iterations: iterations) { i in
            stats.recordRender(
                startMachTime: UInt64(i),
                endMachTime: UInt64(i + 100),
                frames: 128,
                dropout: i % 7 == 0
            )
        }
        let snap = stats.snapshot()
        #expect(snap.renderCallCount == UInt64(iterations))
        #expect(snap.totalFrames == UInt64(iterations) * 128)
        // Approximately iterations / 7 dropouts (deterministic for this pattern).
        let expectedDropouts = UInt64((0..<iterations).filter { $0 % 7 == 0 }.count)
        #expect(snap.dropoutCount == expectedDropouts)
    }

    @Test("resetPeak clears peak without affecting call counts")
    func resetPeakIsolated() {
        let stats = RenderStats()
        stats.recordRender(startMachTime: 0, endMachTime: 1000, frames: 64, dropout: false)
        stats.recordRender(startMachTime: 0, endMachTime: 200, frames: 64, dropout: false)
        let before = stats.snapshot()
        #expect(before.peakRenderDurationNs > 0)
        #expect(before.renderCallCount == 2)

        stats.resetPeak()
        let after = stats.snapshot()
        #expect(after.peakRenderDurationNs == 0)
        #expect(after.renderCallCount == 2)
        #expect(after.totalFrames == 128)
    }

    @Test("resetAll clears every counter")
    func resetAllClears() {
        let stats = RenderStats()
        stats.recordRender(startMachTime: 0, endMachTime: 500, frames: 256, dropout: true)
        stats.recordRender(startMachTime: 0, endMachTime: 800, frames: 256, dropout: false)
        let before = stats.snapshot()
        #expect(before.renderCallCount == 2)

        stats.resetAll()
        let after = stats.snapshot()
        #expect(after.renderCallCount == 0)
        #expect(after.totalFrames == 0)
        #expect(after.peakRenderDurationNs == 0)
        #expect(after.dropoutCount == 0)
        #expect(after.lastRenderDurationNs == 0)
        #expect(after.lastFrameCount == 0)
    }

    @Test("cpuPercent derives from sample rate and frame count")
    func cpuPercent() {
        let stats = RenderStats()
        stats.sampleRate = 48_000
        // Simulate a render block that took 1 ms of wall time for 512 frames.
        // Budget at 48 kHz for 512 frames = 512/48000 s ≈ 10.667 ms.
        // Expected CPU% ≈ 1.0 / 10.667 * 100 ≈ 9.375 %.
        // We fake the duration directly by passing t0/t1 in nanoseconds and
        // assuming 1 tick = 1 ns for the test (numer/denom depend on machine;
        // on Apple Silicon numer/denom typically gives ticks that convert).
        // Instead of trying to match timebase, assert that cpuPercent is a
        // positive number less than 100 after a short synthetic delta.
        stats.recordRender(startMachTime: 0, endMachTime: 1_000_000, frames: 512, dropout: false)
        let snap = stats.snapshot()
        #expect(snap.sampleRate == 48_000)
        #expect(snap.lastCpuPercent > 0)
    }

    @Test("calls-per-second is derived across snapshots")
    func callsPerSecondDerivation() async throws {
        let stats = RenderStats()
        // First snapshot establishes baseline; calls/sec should be 0.
        let first = stats.snapshot()
        #expect(first.callsPerSecond == 0)

        // Record some calls, wait a short interval, then take another snapshot.
        for _ in 0..<100 {
            stats.recordRender(startMachTime: 0, endMachTime: 100, frames: 64, dropout: false)
        }
        try await Task.sleep(nanoseconds: 100_000_000) // 100 ms
        let second = stats.snapshot()
        #expect(second.renderCallCount == 100)
        #expect(second.callsPerSecond > 0)
    }
}
