//
//  AudioCaptureManager.swift
//  ConjureDSPExtension
//
//  Manages reading audio samples from the Rust kernel's ring buffers
//  and computing FFT magnitudes for spectrogram display.
//

import Accelerate
import AppKit
import Combine
import QuartzCore

// MARK: - Custom UI audio frames

/// A tick-synchronous snapshot of audio activity, published to custom HTML/JS
/// UIs via `window.ConjureDSP.audio.onFrame(...)`. Emitted by
/// `AudioCaptureManager` once per display-link tick whenever at least one
/// consumer is active.
///
/// `fftInDB` / `fftOutDB` are included only on ticks that produced a new FFT
/// column (limited by the 50% hop size); on ticks without new FFT data the
/// arrays are nil and subscribers should keep their last value.
struct AudioFrame {
    let rmsIn: Float
    let rmsOut: Float
    let peakIn: Float
    let peakOut: Float
    let fftInDB: [Float]?
    let fftOutDB: [Float]?
    /// Script-published telemetry slots, keyed by declared name (e.g.
    /// `"Gr Db"` → -3.2). `nil` when the loaded preset declares no
    /// telemetry — the common case for legacy scripts. `CustomUIWebView`
    /// only attaches the field to its `audio.onFrame` payload when this
    /// is non-nil and non-empty, so authors don't see a stub key.
    let telemetry: [String: Float]?
    let timestamp: CFTimeInterval
}

// MARK: - ColumnRingBuffer

/// Pre-allocated contiguous ring buffer for FFT magnitude columns.
/// Stores up to `maxColumns` columns of `columnSize` floats each in a single
/// contiguous `[Float]` allocation. Zero per-tick heap allocations.
struct ColumnRingBuffer {
    private var storage: [Float]
    let columnSize: Int
    let maxColumns: Int
    private var writeIndex: Int = 0
    private var readIndex: Int = 0
    private(set) var count: Int = 0

    init(columnSize: Int, maxColumns: Int) {
        self.columnSize = columnSize
        self.maxColumns = maxColumns
        self.storage = [Float](repeating: 0, count: columnSize * maxColumns)
    }

    /// Append a column from a source buffer. Overwrites oldest column if full.
    mutating func append(from source: [Float]) {
        let n = min(source.count, columnSize)
        let offset = writeIndex * columnSize
        for i in 0..<n { storage[offset + i] = source[i] }
        // Zero-fill remainder if source is smaller than columnSize
        for i in n..<columnSize { storage[offset + i] = 0 }
        writeIndex = (writeIndex + 1) % maxColumns
        if count < maxColumns {
            count += 1
        } else {
            // Overwrite oldest — advance read index
            readIndex = (readIndex + 1) % maxColumns
        }
    }

    /// Iterate over all pending columns, calling `body` with a buffer pointer to each.
    /// Resets the ring after iteration. Zero heap allocations.
    mutating func drainAll(_ body: (UnsafeBufferPointer<Float>) -> Void) {
        guard count > 0 else { return }
        storage.withUnsafeBufferPointer { buf in
            for i in 0..<count {
                let idx = (readIndex + i) % maxColumns
                let offset = idx * columnSize
                let slice = UnsafeBufferPointer(rebasing: buf[offset..<(offset + columnSize)])
                body(slice)
            }
        }
        count = 0
        readIndex = 0
        writeIndex = 0
    }

    /// Discard all pending columns without iterating.
    mutating func removeAll() {
        count = 0
        readIndex = 0
        writeIndex = 0
    }
}

// MARK: - CircularFloatBuffer

/// Fixed-capacity circular buffer for audio sample accumulation.
/// Replaces `[Float]` + `append`/`removeFirst` to avoid O(n) copies
/// and capacity ratcheting.
struct CircularFloatBuffer {
    private var storage: [Float]
    private var head: Int = 0     // read position
    private var tail: Int = 0     // write position
    private(set) var count: Int = 0
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        self.storage = [Float](repeating: 0, count: capacity)
    }

    /// Append samples. Drops oldest if buffer would overflow.
    mutating func append(contentsOf source: ArraySlice<Float>) {
        for sample in source {
            storage[tail] = sample
            tail = (tail + 1) % capacity
            if count < capacity {
                count += 1
            } else {
                head = (head + 1) % capacity  // overwrite oldest
            }
        }
    }

    /// Copy the first `n` elements into `dest` (must have at least `n` elements).
    /// Handles wrap-around transparently.
    func copyPrefix(_ n: Int, into dest: inout [Float]) {
        let n = min(n, count)
        let firstChunk = min(n, capacity - head)
        for i in 0..<firstChunk {
            dest[i] = storage[head + i]
        }
        let secondChunk = n - firstChunk
        for i in 0..<secondChunk {
            dest[firstChunk + i] = storage[i]
        }
    }

    /// Advance the read position by `n`, discarding the oldest samples. O(1).
    mutating func dropFirst(_ n: Int) {
        let n = min(n, count)
        head = (head + n) % capacity
        count -= n
    }

    /// Reset to empty state without releasing memory.
    mutating func reset() {
        head = 0
        tail = 0
        count = 0
    }
}

/// Reads audio samples from the Rust kernel's lock-free ring buffers,
/// computes FFT magnitudes via Accelerate/vDSP, and publishes results
/// for spectrogram rendering.
///
/// Operates entirely on the main thread via a `CADisplayLink` tied to
/// the host view's display. When `isActive` is false, no reads or FFT
/// computation occur.
final class AudioCaptureManager: ObservableObject {

    // MARK: - Published FFT Results

    /// Pre-allocated ring buffers for pending FFT magnitude columns.
    /// SpectrogramView drains these each frame via `drainColumns(for:body:)`.
    private var inputColumnRing: ColumnRingBuffer!
    private var outputColumnRing: ColumnRingBuffer!
    private var differenceColumnRing: ColumnRingBuffer!
    private var normalizedDiffColumnRing: ColumnRingBuffer!

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

    /// True when at least one consumer (spectrogram panel, custom UI frame
    /// subscriber, etc.) has registered interest. Computed from `consumers`.
    private(set) var isActive: Bool = false

    /// Ref-counted set of active consumers, keyed by a stable opaque id. A
    /// consumer registers itself when it starts needing audio data and
    /// unregisters when it no longer does. The display link + kernel capture
    /// flag is gated on this set being non-empty.
    private var consumers: Set<String> = []

    /// Register or unregister a consumer. Idempotent per-id. Toggling the
    /// overall set between empty and non-empty starts/stops the display link
    /// and flips the kernel capture flag.
    ///
    /// `id` should be a stable string: `"spectrogram"` for the spectrogram
    /// panel; a per-webview unique string (e.g. ObjectIdentifier hex) for
    /// custom-UI audio-frame subscriptions.
    func setConsumer(id: String, active: Bool) {
        let wasActive = !consumers.isEmpty
        if active { consumers.insert(id) } else { consumers.remove(id) }
        let isActiveNow = !consumers.isEmpty
        guard wasActive != isActiveNow else { return }
        isActive = isActiveNow
        updateCaptureState()
    }

    /// Per-tick audio frames for custom-UI visualisations. Only emits while
    /// capture is active; subscribing alone doesn't activate capture — call
    /// `setConsumer(id:active:)` for that.
    let audioFramePublisher = PassthroughSubject<AudioFrame, Never>()

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
    private static let maxPendingColumns: Int = 256

    // Circular sample accumulators for overlap (fixed capacity, no heap churn)
    private var inputAccumulator: CircularFloatBuffer!
    private var outputAccumulator: CircularFloatBuffer!

    // Linearization buffer for FFT input (circular buffer may wrap)
    private var linearizationBuffer: [Float] = []

    /// When false, skips computing normalized-difference columns (saves ~50μs/window).
    /// Set by SpectrogramSidePanel based on whether that spectrogram mode is visible.
    var isNormalizedDiffEnabled: Bool = true

    // FFT resources (vDSP)
    private var fftSetup: OpaquePointer?  // FFTSetup from vDSP_create_fftsetup
    private var windowBuffer: [Float] = []
    private var fftLog2n: vDSP_Length = 0
    private var fftRealInput: [Float] = []
    private var fftImagInput: [Float] = []
    private var fftRealOutput: [Float] = []
    private var fftImagOutput: [Float] = []

    // Pre-allocated FFT working buffers (reused across computeFFT calls)
    private var fftWindowed: [Float] = []
    private var fftMagnitudes: [Float] = []
    private var fftDBValues: [Float] = []

    // Pre-allocated scratch buffers for difference computation (reused across tick calls)
    private var diffScratch: [Float] = []
    private var normDiffScratch: [Float] = []

    // Pre-allocated scratch buffers for FFT results (reused across tick calls)
    private var fftInputScratch:  [Float] = []
    private var fftOutputScratch: [Float] = []

    // Telemetry: cached metadata + reusable read buffer.
    // The pointer-comparison cache lets us re-parse names only when the
    // kernel's metadata CString changes (i.e. on script load), keeping
    // the per-tick cost down to one comparison + one FFI call when
    // telemetry is in use, zero when it isn't.
    private var telemetryNames: [String] = []
    private var lastTelemetryMetaPtr: UnsafePointer<CChar>?
    private var telemetryReadBuffer: [Float] = []

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
        let halfN = n / 2
        fftLog2n = vDSP_Length(log2(Double(n)))

        if let old = fftSetup {
            vDSP_destroy_fftsetup(old)
        }
        fftSetup = vDSP_create_fftsetup(fftLog2n, FFTRadix(kFFTRadix2))

        // Hann window
        windowBuffer = [Float](repeating: 0, count: n)
        vDSP_hann_window(&windowBuffer, vDSP_Length(n), Int32(vDSP_HANN_NORM))

        // FFT work buffers
        fftRealInput = [Float](repeating: 0, count: halfN)
        fftImagInput = [Float](repeating: 0, count: halfN)
        fftRealOutput = [Float](repeating: 0, count: halfN)
        fftImagOutput = [Float](repeating: 0, count: halfN)

        // Pre-allocated computeFFT scratch buffers
        fftWindowed = [Float](repeating: 0, count: n)
        fftMagnitudes = [Float](repeating: 0, count: halfN)
        fftDBValues = [Float](repeating: 0, count: halfN)

        // Pre-allocated difference scratch buffers
        diffScratch = [Float](repeating: 0, count: halfN)
        normDiffScratch = [Float](repeating: 0, count: halfN)

        // Pre-allocated FFT result scratch buffers
        fftInputScratch  = [Float](repeating: 0, count: halfN)
        fftOutputScratch = [Float](repeating: 0, count: halfN)

        // Linearization buffer for circular accumulator → contiguous FFT input
        linearizationBuffer = [Float](repeating: 0, count: n)

        // Circular accumulators: capacity for one full read + one FFT window
        let accumulatorCapacity = Self.maxReadSamples + n
        inputAccumulator = CircularFloatBuffer(capacity: accumulatorCapacity)
        outputAccumulator = CircularFloatBuffer(capacity: accumulatorCapacity)

        // Column ring buffers: pre-allocated contiguous storage
        inputColumnRing = ColumnRingBuffer(columnSize: halfN, maxColumns: Self.maxPendingColumns)
        outputColumnRing = ColumnRingBuffer(columnSize: halfN, maxColumns: Self.maxPendingColumns)
        differenceColumnRing = ColumnRingBuffer(columnSize: halfN, maxColumns: Self.maxPendingColumns)
        normalizedDiffColumnRing = ColumnRingBuffer(columnSize: halfN, maxColumns: Self.maxPendingColumns)
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
        inputAccumulator.reset()
        outputAccumulator.reset()

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
        // Reset ring buffers and accumulators (memory stays allocated but bounded)
        inputAccumulator?.reset()
        outputAccumulator?.reset()
        inputColumnRing?.removeAll()
        outputColumnRing?.removeAll()
        differenceColumnRing?.removeAll()
        normalizedDiffColumnRing?.removeAll()
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

        // RMS + peak from this tick's samples, for AudioFrame consumers.
        // Zero-cost when no custom UI is subscribed (we skip emit below).
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

        if inputCount > 0 {
            inputAccumulator.append(contentsOf: inputReadBuffer[0..<inputCount])
        }
        if outputCount > 0 {
            outputAccumulator.append(contentsOf: outputReadBuffer[0..<outputCount])
        }

        // Process accumulated samples in lockstep: only produce a column pair when both
        // accumulators have enough data. This guarantees 1:1 temporal alignment between
        // input and output FFT windows, so passthrough shows zero difference.
        let hopSize = Int(Float(fftSize) * hopFraction)
        var producedColumns = false

        while inputAccumulator.count >= fftSize && outputAccumulator.count >= fftSize {
            // Linearize circular buffer into contiguous memory for FFT
            inputAccumulator.copyPrefix(fftSize, into: &linearizationBuffer)
            computeFFT(samples: linearizationBuffer, result: &fftInputScratch)
            inputAccumulator.dropFirst(hopSize)

            outputAccumulator.copyPrefix(fftSize, into: &linearizationBuffer)
            computeFFT(samples: linearizationBuffer, result: &fftOutputScratch)
            outputAccumulator.dropFirst(hopSize)

            // Append to column ring buffers (zero heap allocation — copies into pre-allocated storage)
            inputColumnRing.append(from: fftInputScratch)
            outputColumnRing.append(from: fftOutputScratch)

            computeDifference(input: fftInputScratch, output: fftOutputScratch)
            differenceColumnRing.append(from: diffScratch)

            if isNormalizedDiffEnabled {
                computeNormalizedDifference(inputDB: fftInputScratch, outputDB: fftOutputScratch)
                normalizedDiffColumnRing.append(from: normDiffScratch)
            }
            producedColumns = true
        }

        if producedColumns {
            updateCounter &+= 1
        }

        // Snapshot script-published telemetry, if any. Kept in step with
        // the kernel's cached metadata via pointer comparison so script
        // reloads (which produce a new CString) automatically refresh
        // the name list.
        let telemetry: [String: Float]? = readTelemetry(kernel: kernel)

        // Emit a frame for custom-UI subscribers. FFT arrays only ride along
        // on ticks that produced a new column; otherwise nil. `send` on a
        // subject with no observers is a cheap no-op, so there's no gate.
        let fftIn: [Float]? = producedColumns ? fftInputScratch : nil
        let fftOut: [Float]? = producedColumns ? fftOutputScratch : nil
        audioFramePublisher.send(AudioFrame(
            rmsIn: rmsIn,
            rmsOut: rmsOut,
            peakIn: peakIn,
            peakOut: peakOut,
            fftInDB: fftIn,
            fftOutDB: fftOut,
            telemetry: telemetry,
            timestamp: CACurrentMediaTime()
        ))
    }

    // MARK: - Telemetry

    /// Snapshot the kernel's per-block telemetry slots into a name→value
    /// dict. Returns nil when the loaded preset doesn't declare any
    /// telemetry (the common case for legacy scripts), so consumers can
    /// short-circuit. Cheap: a single CString pointer comparison + FFI
    /// snapshot read when telemetry is active, no allocations or FFI
    /// calls when it isn't.
    private func readTelemetry(kernel: DSPKernelRef) -> [String: Float]? {
        refreshTelemetryNamesIfChanged(kernel: kernel)
        guard !telemetryNames.isEmpty else { return nil }

        let n = Int(dsp_kernel_read_telemetry(
            kernel,
            &telemetryReadBuffer,
            UInt32(telemetryReadBuffer.count)
        ))
        let count = min(n, telemetryNames.count)
        guard count > 0 else { return nil }

        var dict: [String: Float] = [:]
        dict.reserveCapacity(count)
        for i in 0..<count {
            dict[telemetryNames[i]] = telemetryReadBuffer[i]
        }
        return dict
    }

    /// Re-read the kernel's telemetry metadata when it changes. Detected
    /// by pointer comparison against the previously-cached CString — the
    /// kernel allocates a fresh CString on every script load, so a stale
    /// name list is impossible without us noticing. Parses on the
    /// display-link tick at most once per script load (rare).
    private func refreshTelemetryNamesIfChanged(kernel: DSPKernelRef) {
        let ptr = dsp_kernel_telemetry_metadata_json(kernel)
        if ptr == lastTelemetryMetaPtr { return }
        lastTelemetryMetaPtr = ptr
        guard let ptr = ptr else {
            telemetryNames = []
            return
        }
        let json = String(cString: ptr)
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data)
                as? [[String: Any]] else {
            telemetryNames = []
            return
        }
        telemetryNames = array.compactMap { $0["name"] as? String }
        // Buffer must hold at least the full slot count so the FFI
        // snapshot can fill it; pad to 8 (the kernel TELEMETRY_LEN) so
        // we always pass a sensible capacity even if names trim short.
        let needed = max(telemetryNames.count, 8)
        if telemetryReadBuffer.count < needed {
            telemetryReadBuffer = [Float](repeating: 0, count: needed)
        }
    }

    // MARK: - FFT Computation

    /// Compute FFT of the first `fftSize` samples from `samples`, store magnitude dB in `result`.
    private func computeFFT(samples: [Float], result: inout [Float]) {
        guard let fftSetup: OpaquePointer = fftSetup else { return }
        let n = fftSize
        let halfN = n / 2

        // Apply Hann window (reuse pre-allocated buffer)
        vDSP_vmul(samples, 1, windowBuffer, 1, &fftWindowed, 1, vDSP_Length(n))

        // Pack into split complex (even/odd interleave)
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

        // Forward FFT (in-place), reuse pre-allocated magnitude/dB buffers
        fftRealInput.withUnsafeMutableBufferPointer { realBuf in
            fftImagInput.withUnsafeMutableBufferPointer { imagBuf in
                var split = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                vDSP_fft_zrip(fftSetup, &split, 1, fftLog2n, FFTDirection(FFT_FORWARD))

                // Compute magnitude squared
                vDSP_zvmags(&split, 1, &fftMagnitudes, 1, vDSP_Length(halfN))
            }
        }

        // Scale: divide by N^2
        let nFloat = Float(n)
        var scale = 1.0 / (nFloat * nFloat)
        vDSP_vsmul(fftMagnitudes, 1, &scale, &fftMagnitudes, 1, vDSP_Length(halfN))

        // Convert to dB: 10 * log10(magnitude)
        // Add small epsilon to avoid log(0)
        var epsilon: Float = 1e-20
        vDSP_vsadd(fftMagnitudes, 1, &epsilon, &fftMagnitudes, 1, vDSP_Length(halfN))

        var count = Int32(halfN)
        vvlog10f(&fftDBValues, fftMagnitudes, &count)

        var ten: Float = 10.0
        vDSP_vsmul(fftDBValues, 1, &ten, &fftDBValues, 1, vDSP_Length(halfN))

        // Clamp to floor
        var floor = Self.floorDB
        var ceiling: Float = 0.0
        vDSP_vclip(fftDBValues, 1, &floor, &ceiling, &fftDBValues, 1, vDSP_Length(halfN))

        // Copy into caller's buffer (avoids allocation since result is pre-sized by caller)
        for i in 0..<halfN {
            result[i] = fftDBValues[i]
        }
    }

    // MARK: - Column Draining

    /// Drain all pending columns for the given channel, calling `body` for each column.
    /// Zero heap allocations — columns are provided as buffer pointers into pre-allocated storage.
    func drainColumns(for channel: SpectrogramChannel, body: (UnsafeBufferPointer<Float>) -> Void) {
        switch channel {
        case .input: inputColumnRing.drainAll(body)
        case .output: outputColumnRing.drainAll(body)
        case .difference: differenceColumnRing.drainAll(body)
        case .normalizedDifference: normalizedDiffColumnRing.drainAll(body)
        }
    }

    /// Discard all pending columns for the given channel without processing them.
    func discardPendingColumns(for channel: SpectrogramChannel) {
        switch channel {
        case .input: inputColumnRing.removeAll()
        case .output: outputColumnRing.removeAll()
        case .difference: differenceColumnRing.removeAll()
        case .normalizedDifference: normalizedDiffColumnRing.removeAll()
        }
    }

    // MARK: - Difference

    /// Compute per-bin difference: output_dB - input_dB.
    /// Result is written into pre-allocated `diffScratch`.
    private func computeDifference(input: [Float], output: [Float]) {
        let count = min(input.count, output.count)
        guard count > 0 && count <= diffScratch.count else { return }
        vDSP_vsub(input, 1, output, 1, &diffScratch, 1, vDSP_Length(count))
    }

    /// Compute per-bin normalized difference: (S_out - S_in) / (S_out + S_in)
    /// where S = 10^(dB/10) converts from dB back to linear power.
    /// Result is in [-1, 1], written into pre-allocated `normDiffScratch`.
    private func computeNormalizedDifference(inputDB: [Float], outputDB: [Float]) {
        let count = min(inputDB.count, outputDB.count)
        guard count > 0 && count <= normDiffScratch.count else { return }

        for i in 0..<count {
            let sIn = powf(10.0, inputDB[i] / 10.0)
            let sOut = powf(10.0, outputDB[i] / 10.0)
            let denom = sOut + sIn
            normDiffScratch[i] = denom > 1e-20 ? (sOut - sIn) / denom : 0
        }
    }
}
