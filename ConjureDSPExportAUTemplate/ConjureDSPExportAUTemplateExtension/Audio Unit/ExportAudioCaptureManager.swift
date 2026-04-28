//
//  ExportAudioCaptureManager.swift
//  ConjureDSPExportAUTemplateExtension
//
//  Lean audio capture pipeline for the exported AU. Reads the Rust
//  kernel's lock-free ring buffers on a CADisplayLink tick, computes
//  RMS + peak via vDSP, and publishes AudioFrames to custom-UI
//  subscribers via `audioFramePublisher`.
//
//  Contrast with the main extension's AudioCaptureManager: that one owns
//  a spectrogram column pipeline (input/output/difference/normalized-
//  difference ring buffers, updateCounter, column draining). None of
//  that is needed in the export template — there's no spectrogram view.
//  What we keep: consumer ref-counting, FFT when any subscriber opted
//  in, 50% overlap so the FFT cadence matches the main extension's.
//

import Accelerate
import AppKit
import Combine
import QuartzCore

/// Mirrors the main extension's `AudioFrame.telemetry` value type so
/// vector-shape slots round-trip identically inside an exported AU.
enum TelemetryValue {
    case scalar(Float)
    case vector([Float])
}

/// Same shape as the main extension's `AudioFrame` so preset UIs that
/// already subscribe to `window.ConjureDSP.audio.onFrame(...)` work
/// unchanged inside an exported AU.
struct AudioFrame {
    let rmsIn: Float
    let rmsOut: Float
    let peakIn: Float
    let peakOut: Float
    let fftInDB: [Float]?
    let fftOutDB: [Float]?
    /// Script-published telemetry slots, keyed by declared name. `nil`
    /// when the loaded preset declares no telemetry. Mirrors the main
    /// extension's `AudioFrame.telemetry` shape so author UIs that
    /// read `frame.telemetry.gr_db` work unchanged inside an exported AU.
    let telemetry: [String: TelemetryValue]?
    let timestamp: CFTimeInterval
}

/// Reads audio samples from the Rust kernel's lock-free ring buffers,
/// optionally computes FFT magnitudes, and publishes AudioFrames for
/// custom-UI visualisations. CADisplayLink-driven on the main thread.
@MainActor
final class ExportAudioCaptureManager: ObservableObject {
    /// Handle to the kernel whose rings we drain. Setting this while
    /// capture is already running re-arms the capture flag against the
    /// new kernel.
    var kernel: DSPKernelRef? {
        didSet {
            if !consumers.isEmpty {
                updateCaptureState()
            }
        }
    }

    /// Host NSView used to create the display-link. Must be set before
    /// the first consumer registers.
    weak var hostView: NSView?

    /// Per-tick frames published to subscribers. No back-pressure —
    /// Combine's PassthroughSubject drops silently when there are no
    /// observers, so emit calls are cheap even when nothing's listening.
    let audioFramePublisher = PassthroughSubject<AudioFrame, Never>()

    /// Whether any subscriber asked for FFT bins. When true, we run the
    /// forward FFT + dB conversion on each 50%-hop tick; when false we
    /// skip that whole branch and frames carry nil fftInDB/fftOutDB.
    /// Toggled by `ExportCustomUIWebView` when JS flips its FFT flag.
    var includeFFT: Bool = false

    // MARK: - Consumer counting

    /// Set of stable consumer ids currently interested in audio data.
    /// Empty → display link stops and kernel capture flag drops to false.
    private var consumers: Set<String> = []

    /// Register or unregister a consumer. Idempotent per-id. When the
    /// set transitions between empty and non-empty, the display link +
    /// kernel capture flag flip.
    func setConsumer(id: String, active: Bool) {
        let wasActive = !consumers.isEmpty
        if active { consumers.insert(id) } else { consumers.remove(id) }
        let isActiveNow = !consumers.isEmpty
        guard wasActive != isActiveNow else { return }
        updateCaptureState()
    }

    // MARK: - FFT config

    /// FFT window size. Must be a power of 2. 2048 matches the main
    /// extension's default so preset UIs see the same bin layout.
    private let fftSize: Int = 2048
    /// 50% overlap — one FFT column every fftSize/2 samples.
    private let hopFraction: Float = 0.5
    /// dB floor for clamped magnitudes.
    private static let floorDB: Float = -120.0

    // MARK: - Private state

    private var displayLink: CADisplayLink?

    // Read buffers reused across ticks.
    private var inputReadBuffer: [Float]
    private var outputReadBuffer: [Float]
    private static let maxReadSamples: Int = 8192

    // Sample accumulators for FFT overlap.
    private var inputAccumulator: [Float] = []
    private var outputAccumulator: [Float] = []

    // FFT working set.
    private var fftSetup: OpaquePointer?
    private var fftLog2n: vDSP_Length = 0
    private var windowBuffer: [Float] = []
    private var fftRealInput: [Float] = []
    private var fftImagInput: [Float] = []
    private var fftWindowed: [Float] = []
    private var fftMagnitudes: [Float] = []
    private var fftDBValues: [Float] = []
    private var fftInputScratch: [Float] = []
    private var fftOutputScratch: [Float] = []

    // Telemetry — mirrors the main extension's pattern. Cached JSON content
    // (not raw pointer) so that allocator address reuse can't cause a
    // metadata change to be missed and stale slot names paired with new
    // values silently. Same fix as the extension side (commit 9c9fe55).
    private var telemetryNames: [String] = []
    private var telemetryIsVector: [Bool] = []
    private var lastTelemetryMetaJSON: String?
    private var telemetryReadBuffer: [Float] = []
    private static let maxTelemetryVecLen: Int = 4096
    private var telemetryVecScratch: [Float] = [Float](repeating: 0, count: 4096)

    // MARK: - Init

    init() {
        inputReadBuffer = [Float](repeating: 0, count: Self.maxReadSamples)
        outputReadBuffer = [Float](repeating: 0, count: Self.maxReadSamples)
        setupFFT()
    }

    deinit {
        displayLink?.invalidate()
        if let setup = fftSetup {
            vDSP_destroy_fftsetup(setup)
        }
    }

    // MARK: - FFT setup

    private func setupFFT() {
        let n = fftSize
        let halfN = n / 2
        fftLog2n = vDSP_Length(log2(Double(n)))

        if let old = fftSetup {
            vDSP_destroy_fftsetup(old)
        }
        fftSetup = vDSP_create_fftsetup(fftLog2n, FFTRadix(kFFTRadix2))

        windowBuffer = [Float](repeating: 0, count: n)
        vDSP_hann_window(&windowBuffer, vDSP_Length(n), Int32(vDSP_HANN_NORM))

        fftRealInput = [Float](repeating: 0, count: halfN)
        fftImagInput = [Float](repeating: 0, count: halfN)
        fftWindowed = [Float](repeating: 0, count: n)
        fftMagnitudes = [Float](repeating: 0, count: halfN)
        fftDBValues = [Float](repeating: 0, count: halfN)
        fftInputScratch = [Float](repeating: 0, count: halfN)
        fftOutputScratch = [Float](repeating: 0, count: halfN)
    }

    // MARK: - Display link + kernel flag

    private func updateCaptureState() {
        if consumers.isEmpty {
            stopCapture()
        } else {
            startCapture()
        }
    }

    private func startCapture() {
        guard let kernel else { return }
        dsp_kernel_set_capture_enabled(kernel, true)
        inputAccumulator.removeAll(keepingCapacity: true)
        outputAccumulator.removeAll(keepingCapacity: true)

        displayLink?.invalidate()
        guard let view = hostView else { return }
        let link = view.displayLink(target: self, selector: #selector(displayLinkFired(_:)))
        // .common so the tick still fires during gesture tracking (e.g.
        // when the user drags a slider in the custom UI).
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopCapture() {
        displayLink?.invalidate()
        displayLink = nil
        if let kernel {
            dsp_kernel_set_capture_enabled(kernel, false)
        }
        inputAccumulator.removeAll(keepingCapacity: true)
        outputAccumulator.removeAll(keepingCapacity: true)
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        tick()
    }

    // MARK: - Tick

    private func tick() {
        guard let kernel else { return }

        let inputCount = Int(dsp_kernel_read_input_ring(
            kernel, &inputReadBuffer, UInt32(Self.maxReadSamples)
        ))
        let outputCount = Int(dsp_kernel_read_output_ring(
            kernel, &outputReadBuffer, UInt32(Self.maxReadSamples)
        ))

        // RMS + peak straight off the ring buffer read. Cheap even when no
        // subscriber is live — we still emit a frame so subscribers see a
        // steady cadence (the subject no-ops without observers).
        var rmsIn: Float = 0
        var rmsOut: Float = 0
        var peakIn: Float = 0
        var peakOut: Float = 0
        if inputCount > 0 {
            vDSP_rmsqv(inputReadBuffer, 1, &rmsIn, vDSP_Length(inputCount))
            vDSP_maxmgv(inputReadBuffer, 1, &peakIn, vDSP_Length(inputCount))
        }
        if outputCount > 0 {
            vDSP_rmsqv(outputReadBuffer, 1, &rmsOut, vDSP_Length(outputCount))
            vDSP_maxmgv(outputReadBuffer, 1, &peakOut, vDSP_Length(outputCount))
        }

        var producedFFTColumn = false
        if includeFFT {
            if inputCount > 0 {
                inputAccumulator.append(contentsOf: inputReadBuffer[0..<inputCount])
            }
            if outputCount > 0 {
                outputAccumulator.append(contentsOf: outputReadBuffer[0..<outputCount])
            }

            let hopSize = Int(Float(fftSize) * hopFraction)
            while inputAccumulator.count >= fftSize && outputAccumulator.count >= fftSize {
                computeFFT(samples: Array(inputAccumulator[0..<fftSize]), result: &fftInputScratch)
                inputAccumulator.removeFirst(hopSize)
                computeFFT(samples: Array(outputAccumulator[0..<fftSize]), result: &fftOutputScratch)
                outputAccumulator.removeFirst(hopSize)
                producedFFTColumn = true
            }

            // Trim accumulators if they drift high — e.g. the JS side
            // can't keep up with incoming audio and lets samples pile
            // up. Cap at one full window past the last emit so we don't
            // silently allocate unbounded memory.
            if inputAccumulator.count > fftSize * 2 {
                inputAccumulator.removeFirst(inputAccumulator.count - fftSize)
            }
            if outputAccumulator.count > fftSize * 2 {
                outputAccumulator.removeFirst(outputAccumulator.count - fftSize)
            }
        } else {
            // No FFT subscriber → don't let accumulators grow.
            inputAccumulator.removeAll(keepingCapacity: true)
            outputAccumulator.removeAll(keepingCapacity: true)
        }

        let telemetry = readTelemetry(kernel: kernel)

        audioFramePublisher.send(AudioFrame(
            rmsIn: rmsIn,
            rmsOut: rmsOut,
            peakIn: peakIn,
            peakOut: peakOut,
            fftInDB: producedFFTColumn ? fftInputScratch : nil,
            fftOutDB: producedFFTColumn ? fftOutputScratch : nil,
            telemetry: telemetry,
            timestamp: CACurrentMediaTime()
        ))
    }

    // MARK: - Telemetry

    /// Snapshot script-published telemetry into a name→value dict.
    /// Returns nil when the loaded preset declares no slots — same
    /// shape + cost profile as the main extension's implementation.
    private func readTelemetry(kernel: DSPKernelRef) -> [String: TelemetryValue]? {
        refreshTelemetryNamesIfChanged(kernel: kernel)
        guard !telemetryNames.isEmpty else { return nil }

        let n = Int(dsp_kernel_read_telemetry(
            kernel,
            &telemetryReadBuffer,
            UInt32(telemetryReadBuffer.count)
        ))
        let count = min(n, telemetryNames.count)
        guard count > 0 else { return nil }

        var dict: [String: TelemetryValue] = [:]
        dict.reserveCapacity(count)
        for i in 0..<count {
            if i < telemetryIsVector.count && telemetryIsVector[i] {
                let len = Int(dsp_kernel_read_telemetry_vec(
                    kernel,
                    UInt32(i),
                    &telemetryVecScratch,
                    UInt32(telemetryVecScratch.count)
                ))
                if len > 0 {
                    dict[telemetryNames[i]] = .vector(Array(telemetryVecScratch[0..<len]))
                }
            } else {
                dict[telemetryNames[i]] = .scalar(telemetryReadBuffer[i])
            }
        }
        return dict.isEmpty ? nil : dict
    }

    private func refreshTelemetryNamesIfChanged(kernel: DSPKernelRef) {
        let ptr = dsp_kernel_telemetry_metadata_json(kernel)
        let currentJSON: String? = ptr.map { String(cString: $0) }
        if currentJSON == lastTelemetryMetaJSON { return }
        lastTelemetryMetaJSON = currentJSON
        guard let json = currentJSON else {
            telemetryNames = []
            telemetryIsVector = []
            return
        }
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data)
                as? [[String: Any]] else {
            telemetryNames = []
            telemetryIsVector = []
            return
        }
        telemetryNames = array.compactMap { $0["name"] as? String }
        telemetryIsVector = array.map { ($0["shape"] as? String) == "vector" }
        let needed = max(telemetryNames.count, 16)
        if telemetryReadBuffer.count < needed {
            telemetryReadBuffer = [Float](repeating: 0, count: needed)
        }
    }

    // MARK: - FFT

    /// Compute forward FFT of `samples[0..<fftSize]`, write magnitude-in-dB
    /// bins into `result`. Mirrors the main extension's computeFFT shape
    /// (Hann → split complex → zrip → magnitude² → scale by N² → 10·log10
    /// → clamp) so bin values match bit-for-bit.
    private func computeFFT(samples: [Float], result: inout [Float]) {
        guard let fftSetup else { return }
        let n = fftSize
        let halfN = n / 2

        vDSP_vmul(samples, 1, windowBuffer, 1, &fftWindowed, 1, vDSP_Length(n))

        fftWindowed.withUnsafeBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { complexPtr in
                fftRealInput.withUnsafeMutableBufferPointer { realBuf in
                    fftImagInput.withUnsafeMutableBufferPointer { imagBuf in
                        var split = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                        vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(halfN))
                    }
                }
            }
        }

        fftRealInput.withUnsafeMutableBufferPointer { realBuf in
            fftImagInput.withUnsafeMutableBufferPointer { imagBuf in
                var split = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                vDSP_fft_zrip(fftSetup, &split, 1, fftLog2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &fftMagnitudes, 1, vDSP_Length(halfN))
            }
        }

        let nFloat = Float(n)
        var scale = 1.0 / (nFloat * nFloat)
        vDSP_vsmul(fftMagnitudes, 1, &scale, &fftMagnitudes, 1, vDSP_Length(halfN))

        var epsilon: Float = 1e-20
        vDSP_vsadd(fftMagnitudes, 1, &epsilon, &fftMagnitudes, 1, vDSP_Length(halfN))

        var count = Int32(halfN)
        vvlog10f(&fftDBValues, fftMagnitudes, &count)

        var ten: Float = 10.0
        vDSP_vsmul(fftDBValues, 1, &ten, &fftDBValues, 1, vDSP_Length(halfN))

        var floor = Self.floorDB
        var ceiling: Float = 0.0
        vDSP_vclip(fftDBValues, 1, &floor, &ceiling, &fftDBValues, 1, vDSP_Length(halfN))

        for i in 0..<halfN {
            result[i] = fftDBValues[i]
        }
    }
}
