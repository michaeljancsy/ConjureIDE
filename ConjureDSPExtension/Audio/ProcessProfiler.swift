//
//  ProcessProfiler.swift
//  ConjureDSPExtension
//
//  Polls real-time process function timing from the Rust kernel
//  and publishes statistics for the status bar display.
//

import Combine
import Foundation

/// Polls the Rust kernel's profiler atomics on a timer and publishes
/// live process function timing for the UI status bar.
final class ProcessProfiler: ObservableObject {

    /// Most recent backend.process() duration in milliseconds.
    @Published var currentMs: Double = 0

    /// Exponential moving average of process duration (~0.5s smoothing).
    @Published var avgMs: Double = 0

    /// Decaying peak process duration (fades over a few seconds).
    @Published var peakMs: Double = 0

    /// Audio budget in milliseconds (maxFrames / sampleRate * 1000).
    @Published var budgetMs: Double = 0

    /// Whether the profiler has live data (non-zero avg).
    var isActive: Bool { avgMs > 0 }

    // MARK: - Kernel Reference

    var kernel: OpaquePointer? {
        didSet { poll() }
    }

    var sampleRate: Double = 44100 {
        didSet { updateBudget() }
    }

    var maxFrames: UInt32 = 1024 {
        didSet { updateBudget() }
    }

    deinit { stop() }

    // MARK: - Timer

    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        updateBudget()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Polling

    private func poll() {
        guard let kernel = kernel else { return }
        currentMs = Double(dsp_kernel_profiler_current_us(kernel)) / 1000.0
        avgMs = Double(dsp_kernel_profiler_avg_us(kernel)) / 1000.0
        peakMs = Double(dsp_kernel_profiler_peak_us(kernel)) / 1000.0
    }

    private func updateBudget() {
        guard sampleRate > 0 else { return }
        budgetMs = Double(maxFrames) / sampleRate * 1000.0
    }
}
