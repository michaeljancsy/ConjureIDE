//
//  AudioCaptureManager.swift
//  BearBoneExtension
//
//  Manages reading audio samples from the Rust kernel's ring buffers
//  and computing FFT magnitudes for spectrogram display.
//

import Accelerate
import AppKit
import Combine
import QuartzCore

/// Reads audio samples from the Rust kernel's lock-free ring buffers,
/// computes FFT magnitudes via Accelerate/vDSP, and publishes results
/// for spectrogram rendering.
///
/// Operates entirely on the main thread via a `CADisplayLink` tied to
/// the host view's display. When `isActive` is false, no reads or FFT
/// computation occur.
final class AudioCaptureManager: ObservableObject {

    // MARK: - Published FFT Results

    /// Queued FFT magnitude snapshots for the input signal.
    /// Each entry is one FFT window's worth of dB magnitudes (length = fftSize / 2).
    /// SpectrogramView drains this queue each frame, appending one column per entry.
    var pendingInputColumns: [[Float]] = []

    /// Queued FFT magnitude snapshots for the output signal.
    var pendingOutputColumns: [[Float]] = []

    /// Queued difference magnitude snapshots (output_dB - input_dB per bin).
    var pendingDifferenceColumns: [[Float]] = []

    /// Queued normalized difference: (S_out - S_in) / (S_out + S_in) per bin, in [-1, 1].
    var pendingNormalizedDifferenceColumns: [[Float]] = []

    /// Monotonically increasing counter, incremented every time new FFT data
    /// is queued. Use this in `.onChange` to trigger SpectrogramView updates.
    /// Uses Int comparison (O(1)) rather than array comparison (O(n)).
    @Published var updateCounter: Int = 0

    // MARK: - Configuration

    /// FFT size (number of samples per FFT window). Must be a power of 2.
    var fftSize: Int = 2048 {
        didSet {
            guard fftSize != oldValue else { return }
            setupFFT()
        }
    }

    /// Floor dB value — magnitudes below this are clamped.
    static let floorDB: Float = -120.0

    /// Hop size as a fraction of fftSize (0.5 = 50% overlap).
    private let hopFraction: Float = 0.5

    // MARK: - State

    /// When true, reads from ring buffers and computes FFT.
    /// Setting to false stops the display link and disables capture in the kernel.
    var isActive: Bool = false {
        didSet {
            guard isActive != oldValue else { return }
            updateCaptureState()
        }
    }

    /// Reference to the Rust DSP kernel (set once after AU creation).
    var kernel: DSPKernelRef? {
        didSet {
            if isActive {
                updateCaptureState()
            }
        }
    }

    /// The host NSView used to create a display-synced CADisplayLink.
    /// Must be set before activating capture.
    weak var hostView: NSView?

    // MARK: - Private

    private var displayLink: CADisplayLink?

    // Read buffers (reused across timer ticks)
    private var inputReadBuffer: [Float] = []
    private var outputReadBuffer: [Float] = []
    private static let maxReadSamples: Int = 8192

    // Sample accumulators for overlap
    private var inputAccumulator: [Float] = []
    private var outputAccumulator: [Float] = []

    // FFT resources (vDSP)
    private var fftSetup: OpaquePointer?  // FFTSetup from vDSP_create_fftsetup
    private var windowBuffer: [Float] = []
    private var fftLog2n: vDSP_Length = 0
    private var fftRealInput: [Float] = []
    private var fftImagInput: [Float] = []
    private var fftRealOutput: [Float] = []
    private var fftImagOutput: [Float] = []

    // MARK: - Init

    init() {
        inputReadBuffer = [Float](repeating: 0, count: Self.maxReadSamples)
        outputReadBuffer = [Float](repeating: 0, count: Self.maxReadSamples)
        setupFFT()
    }

    deinit {
        displayLink?.invalidate()
        if let kernel = kernel {
            dsp_kernel_set_capture_enabled(kernel, false)
        }
        if let setup = fftSetup {
            vDSP_destroy_fftsetup(setup)
        }
    }

    // MARK: - FFT Setup

    private func setupFFT() {
        let n = fftSize
        fftLog2n = vDSP_Length(log2(Double(n)))

        if let old = fftSetup {
            vDSP_destroy_fftsetup(old)
        }
        fftSetup = vDSP_create_fftsetup(fftLog2n, FFTRadix(kFFTRadix2))

        // Hann window
        windowBuffer = [Float](repeating: 0, count: n)
        vDSP_hann_window(&windowBuffer, vDSP_Length(n), Int32(vDSP_HANN_NORM))

        // FFT work buffers
        fftRealInput = [Float](repeating: 0, count: n / 2)
        fftImagInput = [Float](repeating: 0, count: n / 2)
        fftRealOutput = [Float](repeating: 0, count: n / 2)
        fftImagOutput = [Float](repeating: 0, count: n / 2)

        // Reset accumulators
        inputAccumulator.removeAll(keepingCapacity: true)
        outputAccumulator.removeAll(keepingCapacity: true)

        // Reset pending columns
        pendingInputColumns.removeAll()
        pendingOutputColumns.removeAll()
        pendingDifferenceColumns.removeAll()
        pendingNormalizedDifferenceColumns.removeAll()
    }

    // MARK: - Display Link Management

    private func updateCaptureState() {
        if isActive {
            startCapture()
        } else {
            stopCapture()
        }
    }

    private func startCapture() {
        guard let kernel = kernel else { return }
        dsp_kernel_set_capture_enabled(kernel, true)

        // Reset accumulators
        inputAccumulator.removeAll(keepingCapacity: true)
        outputAccumulator.removeAll(keepingCapacity: true)

        displayLink?.invalidate()

        guard let view = hostView else { return }
        let link = view.displayLink(target: self, selector: #selector(displayLinkFired(_:)))
        // Add to .common modes so it fires during gesture tracking
        // (e.g. slider drags) — not just the default run loop mode.
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopCapture() {
        displayLink?.invalidate()
        displayLink = nil
        if let kernel = kernel {
            dsp_kernel_set_capture_enabled(kernel, false)
        }
    }

    // MARK: - Display Link Callback

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        tick()
    }

    private func tick() {
        guard let kernel = kernel else { return }

        // Read available samples from ring buffers
        let inputCount = Int(dsp_kernel_read_input_ring(
            kernel,
            &inputReadBuffer,
            UInt32(Self.maxReadSamples)
        ))
        let outputCount = Int(dsp_kernel_read_output_ring(
            kernel,
            &outputReadBuffer,
            UInt32(Self.maxReadSamples)
        ))

        if inputCount > 0 {
            inputAccumulator.append(contentsOf: inputReadBuffer[0..<inputCount])
        }
        if outputCount > 0 {
            outputAccumulator.append(contentsOf: outputReadBuffer[0..<outputCount])
        }

        // Process accumulated samples with overlap, queuing each FFT result
        let hopSize = Int(Float(fftSize) * hopFraction)
        var newInputColumns: [[Float]] = []
        var newOutputColumns: [[Float]] = []

        while inputAccumulator.count >= fftSize {
            var mags = [Float](repeating: 0, count: fftSize / 2)
            computeFFT(samples: &inputAccumulator, result: &mags)
            inputAccumulator.removeFirst(hopSize)
            newInputColumns.append(mags)
        }

        while outputAccumulator.count >= fftSize {
            var mags = [Float](repeating: 0, count: fftSize / 2)
            computeFFT(samples: &outputAccumulator, result: &mags)
            outputAccumulator.removeFirst(hopSize)
            newOutputColumns.append(mags)
        }

        // Queue all columns, computing difference for each pair
        let columnCount = max(newInputColumns.count, newOutputColumns.count)
        if columnCount > 0 {
            // Keep track of latest input/output for difference when counts don't match
            var lastInput = newInputColumns.last ?? pendingInputColumns.last
                ?? [Float](repeating: Self.floorDB, count: fftSize / 2)
            var lastOutput = newOutputColumns.last ?? pendingOutputColumns.last
                ?? [Float](repeating: Self.floorDB, count: fftSize / 2)

            for i in 0..<columnCount {
                if i < newInputColumns.count {
                    lastInput = newInputColumns[i]
                    pendingInputColumns.append(lastInput)
                } else {
                    pendingInputColumns.append(lastInput)
                }

                if i < newOutputColumns.count {
                    lastOutput = newOutputColumns[i]
                    pendingOutputColumns.append(lastOutput)
                } else {
                    pendingOutputColumns.append(lastOutput)
                }

                pendingDifferenceColumns.append(computeDifference(input: lastInput, output: lastOutput))
                pendingNormalizedDifferenceColumns.append(computeNormalizedDifference(inputDB: lastInput, outputDB: lastOutput))
            }

            updateCounter &+= 1
        }
    }

    // MARK: - FFT Computation

    /// Compute FFT of the first `fftSize` samples, store magnitude dB in `result`.
    private func computeFFT(samples: inout [Float], result: inout [Float]) {
        guard let fftSetup: OpaquePointer = fftSetup else { return }
        let n = fftSize
        let halfN = n / 2

        // Apply Hann window
        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(samples, 1, windowBuffer, 1, &windowed, 1, vDSP_Length(n))

        // Pack into split complex (even/odd interleave)
        windowed.withUnsafeBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { complexPtr in
                fftRealInput.withUnsafeMutableBufferPointer { realBuf in
                    fftImagInput.withUnsafeMutableBufferPointer { imagBuf in
                        var split = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                        vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(halfN))
                    }
                }
            }
        }

        // Forward FFT (in-place)
        var magnitudes = [Float](repeating: 0, count: halfN)
        fftRealInput.withUnsafeMutableBufferPointer { realBuf in
            fftImagInput.withUnsafeMutableBufferPointer { imagBuf in
                var split = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                vDSP_fft_zrip(fftSetup, &split, 1, fftLog2n, FFTDirection(FFT_FORWARD))

                // Compute magnitude squared
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(halfN))
            }
        }

        // Scale: divide by N^2
        let nFloat = Float(n)
        var scale = 1.0 / (nFloat * nFloat)
        vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(halfN))

        // Convert to dB: 10 * log10(magnitude)
        // Add small epsilon to avoid log(0)
        var epsilon: Float = 1e-20
        vDSP_vsadd(magnitudes, 1, &epsilon, &magnitudes, 1, vDSP_Length(halfN))

        var dbValues = [Float](repeating: 0, count: halfN)
        var count = Int32(halfN)
        vvlog10f(&dbValues, magnitudes, &count)

        var ten: Float = 10.0
        vDSP_vsmul(dbValues, 1, &ten, &dbValues, 1, vDSP_Length(halfN))

        // Clamp to floor
        var floor = Self.floorDB
        var ceiling: Float = 0.0
        vDSP_vclip(dbValues, 1, &floor, &ceiling, &dbValues, 1, vDSP_Length(halfN))

        result = dbValues
    }

    // MARK: - Column Draining

    /// Remove and return all pending columns for the given channel.
    /// Called by SpectrogramView to consume queued FFT results.
    func drainColumns(for channel: SpectrogramChannel) -> [[Float]] {
        switch channel {
        case .input:
            let cols = pendingInputColumns
            pendingInputColumns.removeAll(keepingCapacity: true)
            return cols
        case .output:
            let cols = pendingOutputColumns
            pendingOutputColumns.removeAll(keepingCapacity: true)
            return cols
        case .difference:
            let cols = pendingDifferenceColumns
            pendingDifferenceColumns.removeAll(keepingCapacity: true)
            return cols
        case .normalizedDifference:
            let cols = pendingNormalizedDifferenceColumns
            pendingNormalizedDifferenceColumns.removeAll(keepingCapacity: true)
            return cols
        }
    }

    // MARK: - Difference

    /// Compute per-bin difference: output_dB - input_dB
    private func computeDifference(input: [Float], output: [Float]) -> [Float] {
        let count = min(input.count, output.count)
        guard count > 0 else { return [] }

        var diff = [Float](repeating: 0, count: count)
        vDSP_vsub(input, 1, output, 1, &diff, 1, vDSP_Length(count))
        return diff
    }

    /// Compute per-bin normalized difference: (S_out - S_in) / (S_out + S_in)
    /// where S = 10^(dB/10) converts from dB back to linear power.
    /// Result is in [-1, 1]. Returns 0 where both signals are near silence.
    private func computeNormalizedDifference(inputDB: [Float], outputDB: [Float]) -> [Float] {
        let count = min(inputDB.count, outputDB.count)
        guard count > 0 else { return [] }

        var result = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let sIn = powf(10.0, inputDB[i] / 10.0)
            let sOut = powf(10.0, outputDB[i] / 10.0)
            let denom = sOut + sIn
            if denom > 1e-20 {
                result[i] = (sOut - sIn) / denom
            }
        }
        return result
    }
}
