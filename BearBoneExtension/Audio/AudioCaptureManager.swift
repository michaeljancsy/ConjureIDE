//
//  AudioCaptureManager.swift
//  BearBoneExtension
//
//  Manages reading audio samples from the Rust kernel's ring buffers
//  and computing FFT magnitudes for spectrogram display.
//

import Accelerate
import Combine
import Foundation

/// Reads audio samples from the Rust kernel's lock-free ring buffers,
/// computes FFT magnitudes via Accelerate/vDSP, and publishes results
/// for spectrogram rendering.
///
/// Operates entirely on the main thread via a Timer.
/// When `isActive` is false, no reads or FFT computation occur.
final class AudioCaptureManager: ObservableObject {

    // MARK: - Published FFT Results

    /// FFT magnitudes in dB for the input (pre-processing) signal.
    /// Array length = fftSize / 2. Values clamped to [floorDB, 0].
    @Published var inputMagnitudes: [Float] = []

    /// FFT magnitudes in dB for the output (post-processing) signal.
    @Published var outputMagnitudes: [Float] = []

    /// Difference magnitudes: output_dB - input_dB per bin.
    /// Positive = boost, negative = cut, zero = unchanged.
    @Published var differenceMagnitudes: [Float] = []

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
    /// Setting to false stops the timer and disables capture in the kernel.
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

    // MARK: - Private

    private var timer: Timer?
    private let timerInterval: TimeInterval = 1.0 / 60.0 // ~60 Hz

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
        timer?.invalidate()
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

        // Reset published data
        let binCount = n / 2
        inputMagnitudes = [Float](repeating: Self.floorDB, count: binCount)
        outputMagnitudes = [Float](repeating: Self.floorDB, count: binCount)
        differenceMagnitudes = [Float](repeating: 0, count: binCount)
    }

    // MARK: - Timer Management

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

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: timerInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func stopCapture() {
        timer?.invalidate()
        timer = nil
        if let kernel = kernel {
            dsp_kernel_set_capture_enabled(kernel, false)
        }
    }

    // MARK: - Timer Tick

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

        // Process accumulated samples with overlap
        let hopSize = Int(Float(fftSize) * hopFraction)
        var inputUpdated = false
        var outputUpdated = false

        while inputAccumulator.count >= fftSize {
            computeFFT(samples: &inputAccumulator, result: &inputMagnitudes)
            inputAccumulator.removeFirst(hopSize)
            inputUpdated = true
        }

        while outputAccumulator.count >= fftSize {
            computeFFT(samples: &outputAccumulator, result: &outputMagnitudes)
            outputAccumulator.removeFirst(hopSize)
            outputUpdated = true
        }

        // Compute difference when both updated
        if inputUpdated || outputUpdated {
            computeDifference()
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

    // MARK: - Difference

    /// Compute per-bin difference: output_dB - input_dB
    private func computeDifference() {
        let count = min(inputMagnitudes.count, outputMagnitudes.count)
        guard count > 0 else { return }

        var diff = [Float](repeating: 0, count: count)
        vDSP_vsub(inputMagnitudes, 1, outputMagnitudes, 1, &diff, 1, vDSP_Length(count))
        differenceMagnitudes = diff
    }
}
