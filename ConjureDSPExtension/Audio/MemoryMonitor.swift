//
//  MemoryMonitor.swift
//  ConjureDSPExtension
//
//  Polls process RSS and WASM memory from the Rust kernel on a timer
//  and detects monotonic growth patterns that indicate memory leaks
//  in user DSP scripts.
//

import Combine
import Foundation

/// Leak detection status levels.
enum LeakStatus: String {
    case ok
    case warning
    case critical
}

/// Polls the Rust kernel's memory state on a timer and publishes
/// live memory statistics plus leak detection for the UI status bar.
final class MemoryMonitor: ObservableObject {

    /// Current process resident memory in MB.
    @Published var currentResidentMB: Double = 0

    /// RSS baseline when the current script was loaded, in MB.
    @Published var baselineMB: Double = 0

    /// Growth since script load (current - baseline), in MB.
    @Published var growthMB: Double = 0

    /// Current WASM linear memory size in MB (0 if Python backend).
    @Published var wasmMemoryMB: Double = 0

    /// Estimated memory growth rate in MB per minute.
    @Published var growthRateMBPerMin: Double = 0

    /// Current leak detection status.
    @Published var leakStatus: LeakStatus = .ok

    // MARK: - Kernel Reference

    var kernel: OpaquePointer? {
        didSet { poll() }
    }

    deinit { stop() }

    // MARK: - Timer

    private var timer: Timer?

    /// Polling interval in seconds.
    private let pollInterval: TimeInterval = 5.0

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Sliding Window

    /// Circular buffer of recent RSS samples for trend analysis.
    private var samples: [UInt64] = []

    /// Last known baseline — used to detect script reloads.
    private var lastBaseline: UInt64 = 0

    /// Maximum samples to keep (1 minute at 5s intervals = 12 samples).
    private let maxSamples = 12

    /// Threshold: if this many of the last maxSamples show growth, warn.
    private let growthCountThreshold = 10

    /// Minimum absolute growth (MB) to trigger warning.
    private let growthMBThreshold: Double = 5.0

    /// Growth rate (MB/min) that triggers critical status.
    private let criticalRateMBPerMin: Double = 20.0

    /// Reset analysis state (called when a new script is loaded).
    func reset() {
        samples.removeAll()
        lastBaseline = 0
        growthRateMBPerMin = 0
        leakStatus = .ok
    }

    // MARK: - Polling

    private func poll() {
        guard let k = kernel else { return }

        let residentBytes = dsp_kernel_process_resident_bytes()
        let baselineBytes = dsp_kernel_memory_baseline_bytes(k)
        let wasmBytes = dsp_kernel_wasm_memory_bytes(k)

        currentResidentMB = Double(residentBytes) / 1_048_576.0
        baselineMB = Double(baselineBytes) / 1_048_576.0
        growthMB = currentResidentMB - baselineMB
        wasmMemoryMB = Double(wasmBytes) / 1_048_576.0

        // Detect baseline change (new script loaded) → reset analysis
        if baselineBytes != lastBaseline && baselineBytes != 0 {
            samples.removeAll()
            growthRateMBPerMin = 0
            leakStatus = .ok
        }
        lastBaseline = baselineBytes

        // Add to sliding window
        samples.append(residentBytes)
        if samples.count > maxSamples {
            samples.removeFirst()
        }

        // Need at least 3 samples for trend analysis
        guard samples.count >= 3 else {
            leakStatus = .ok
            return
        }

        // Count samples that show growth over the previous sample
        var growthCount = 0
        for i in 1..<samples.count {
            if samples[i] > samples[i - 1] {
                growthCount += 1
            }
        }

        // Estimate growth rate from first and last sample in window
        let windowDurationMin = Double(samples.count - 1) * pollInterval / 60.0
        let windowGrowthMB = Double(Int64(samples.last!) - Int64(samples.first!)) / 1_048_576.0
        if windowDurationMin > 0 {
            growthRateMBPerMin = windowGrowthMB / windowDurationMin
        }

        // Determine leak status
        if growthRateMBPerMin >= criticalRateMBPerMin {
            leakStatus = .critical
        } else if growthCount >= growthCountThreshold && growthMB >= growthMBThreshold {
            leakStatus = .warning
        } else {
            leakStatus = .ok
        }
    }
}
