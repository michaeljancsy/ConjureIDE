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

/// A single telemetry slot value. Scalar slots produce one float per
/// block; vector slots produce one float per audio frame in the current
/// render block (length matches the host's frame_count, ≤ MAX_FRAMES).
enum TelemetryValue {
    case scalar(Float)
    case vector([Float])
}

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
    /// Host sample rate at the time the frame was captured. Lets UIs that
    /// map FFT bins to absolute frequencies (e.g. the eq3 spectrum overlay)
    /// stay correct at non-48k rates instead of hardcoding 48000.
    let sampleRate: Double
    /// Script-published telemetry slots, keyed by declared name (e.g.
    /// `"Gr Db"` → `.scalar(-3.2)`, `"Scope"` → `.vector([...])`).
    /// `nil` when the loaded preset declares no telemetry — the common
    /// case for legacy scripts. `CustomUIWebView` only attaches the field
    /// to its `audio.onFrame` payload when this is non-nil and non-empty.
    let telemetry: [String: TelemetryValue]?
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

    /// Host sample rate. Set by the view controller from the AU's output bus
    /// format on capture activation. Stamped into every emitted `AudioFrame`
    /// so UIs that need absolute frequencies (e.g. spectrum overlays) don't
    /// have to hardcode an assumption.
    var sampleRate: Double = 48000

    /// FFT size (number of samples per FFT window). Must be a power of 2.
    var fftSize: Int = 2048 {
        didSet {
            guard fftSize != oldValue else { return }
            setupFFT()
        }
    }

    /// Floor dB value — magnitudes below this are clamped by the FFT path.
    /// Numerical guard only; not the value used for color mapping.
    static let floorDB: Float = -120.0

    /// Visual floor for the magma spectrogram colormap. Values below this dB
    /// threshold paint as silence (deep navy / near-black) regardless of how
    /// far below they sit in the FFT output.
    ///
    /// Tuned so that Hann sidelobe content past the third–fourth octave from a
    /// strong peak reads as silence rather than as a wide purple haze. A pure
    /// 440 Hz sine through a 2048-point Hann has first sidelobe at ~−32 dB
    /// and rolls off ~18 dB/octave, so −90 dB lands just past the audible
    /// sidelobe region.
    ///
    /// Presentation-only: the column rings still store dB values clamped at
    /// `floorDB`, so changing this constant is a pure re-render — no audio
    /// reprocessing required.
    static let visualFloorDB: Float = -90.0

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

    // Per-bin smoother state for the spectrogram column rings only.
    // Damps the small phase-dependent magnitude cross-term that windowed-sine
    // FFT produces between hops — visible in the screenshot as vertical
    // striping in sidelobe bins even after the rendering-interpolation fix.
    // The smoother is asymmetric (attack-snap, gentle-release on small drops,
    // hard-step bypass on large drops) so transients still render as sharp
    // single-column events; only quasi-stationary wobble gets averaged.
    // `fftInputScratch` / `fftOutputScratch` stay un-smoothed so the diff and
    // normDiff channels (and the audioFramePublisher) continue to see raw dB.
    private var fftInputEMA:  [Float] = []
    private var fftOutputEMA: [Float] = []

    // Telemetry: cached metadata + reusable read buffer.
    // The cached-JSON string lets us re-parse names only when the
    // kernel's metadata content changes (i.e. on script load), keeping
    // the per-tick cost down to one C-string read + one Swift String
    // equality check when telemetry is in use, zero when it isn't.
    //
    // Earlier we cached the raw pointer and compared addresses — that
    // misses the case where the system allocator hands the new CString
    // the same address as the freed old one, leaving stale slot names
    // paired with new values. Comparing the JSON content costs one
    // String() construction per tick (cheap; metadata strings are tiny)
    // and is correctness-by-construction.
    private var telemetryNames: [String] = []
    /// Parallel to `telemetryNames`: true when slot is `"vector"` shape,
    /// false for scalar (or shape missing — legacy default).
    private var telemetryIsVector: [Bool] = []
    private var lastTelemetryMetaJSON: String?
    private var telemetryReadBuffer: [Float] = []

    /// Wall time of the last tick that observed forward progress on the
    /// audio thread (i.e. read >0 samples from the kernel ring). Used to
    /// detect a stalled audio thread (host paused, transport stopped) and
    /// suppress telemetry instead of replaying the last cached value
    /// forever. Renders typically deliver a block every 5–21 ms at 48 kHz,
    /// so a 50 ms deadband is comfortably larger than any normal gap.
    ///
    /// Initialized to `CACurrentMediaTime()` (system uptime in seconds) at
    /// construction so the staleness check has a meaningful baseline before
    /// the first audio tick. Initializing to 0 made `now - last` evaluate
    /// to many-seconds on the very first call, theoretically suppressing
    /// telemetry until audio first ticked. In practice the publish gate
    /// already drops empty-drain ticks so this couldn't surface, but the
    /// explicit init makes the invariant clear.
    private var lastRenderActivityTimestamp: CFTimeInterval = CACurrentMediaTime()
    private static let telemetryStaleThreshold: CFTimeInterval = 0.050
    /// Shared scratch for vector-telemetry reads. Sized to the kernel's
    /// `MAX_FRAMES` (4096) — the kernel truncates anything longer, so
    /// this is sufficient for any host buffer size.
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

        // EMA state for spectrogram smoothing — init to floorDB so the first
        // column post-resize attack-snaps to actual signal instead of ramping
        // up from 0 dB.
        fftInputEMA  = [Float](repeating: Self.floorDB, count: halfN)
        fftOutputEMA = [Float](repeating: Self.floorDB, count: halfN)

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

        // Reset EMA state so resuming capture after a stop doesn't carry
        // stale per-bin magnitudes from a prior session.
        for i in 0..<fftInputEMA.count {
            fftInputEMA[i]  = Self.floorDB
            fftOutputEMA[i] = Self.floorDB
        }

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

        // Stamp render activity. The audio thread only writes new samples
        // into the ring while the host is calling render, so a tick with
        // zero samples on both rings means the render path is stalled.
        if inputCount > 0 || outputCount > 0 {
            lastRenderActivityTimestamp = CACurrentMediaTime()
        }

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

            // Smooth each bin into per-channel EMA state, then append the
            // smoothed values to the spectrogram column rings. The diff /
            // normDiff path below continues to consume the un-smoothed
            // `fftInputScratch` / `fftOutputScratch`, so the passthrough-
            // zero-diff invariant is preserved. See `fftInputEMA` docstring
            // above for the asymmetric-smoother rationale.
            applySpectrogramSmoothing(scratch: fftInputScratch,  state: &fftInputEMA)
            applySpectrogramSmoothing(scratch: fftOutputScratch, state: &fftOutputEMA)

            // Append to column ring buffers (zero heap allocation — copies into pre-allocated storage)
            inputColumnRing.append(from: fftInputEMA)
            outputColumnRing.append(from: fftOutputEMA)

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
        let telemetry: [String: TelemetryValue]? = readTelemetry(kernel: kernel)

        // Emit a frame for custom-UI subscribers. FFT arrays only ride along
        // on ticks that produced a new column; otherwise nil. `send` on a
        // subject with no observers is a cheap no-op, so there's no gate.
        //
        // Three classes of bad-data tick are filtered out here:
        //
        // 1. **Empty drains** (`inputCount == 0 && outputCount == 0`).
        //    The CADisplayLink fires at display rate (60 Hz, or 120 Hz on
        //    ProMotion); DAW hosts render audio in larger blocks (Ableton:
        //    2048 frames at 48 kHz = ~23 Hz). On ProMotion ~80% of ticks
        //    see both rings empty. Without filtering, we'd publish
        //    `peakIn = peakOut = 0` (var-init defaults), which the time-
        //    anchored UI would draw as a real -120 dB sample.
        //
        // 2. **Mismatched ticks** (exactly one of `inputCount`/`outputCount`
        //    is 0). The audio thread writes the input ring at the start of
        //    a render block and the output ring at the end, with the
        //    script's `process()` in between (~10 ms). If a UI tick fires
        //    in that window, one ring has data and the other doesn't.
        //    Publishing those produces consecutive ring entries with one
        //    fill present and the other missing — visible as lighter or
        //    medium-grey "phantom" strips. Skipping costs us one render
        //    block's contribution to the visualization, which the time-
        //    anchored renderer interpolates over invisibly.
        //
        // 3. **All-zero buffers** (`peakIn == 0 && peakOut == 0` even when
        //    both counts > 0). Sometimes the host hands us a full block of
        //    pure silence (e.g. brief Ableton transport hiccups, or the AU
        //    being called from an auxiliary render path). Publishing those
        //    produces real -120 dB ring entries → visible drops to the
        //    -60 dB floor in the level fill. Audio output to the DAW is
        //    unaffected; the silence is purely an artifact of the capture
        //    ring's view of input.
        //
        // Cases 2 and 3 also show up under the diagnostic as `kind=mismatch`
        // and `kind=zeroBoth` respectively. The kernel-side root cause for
        // (3) is still being investigated; this gate is a UI-side
        // suppression so the visualization stays clean while we dig.
        if inputCount > 0 && outputCount > 0 && (peakIn > 0 || peakOut > 0) {
            let fftIn: [Float]? = producedColumns ? fftInputScratch : nil
            let fftOut: [Float]? = producedColumns ? fftOutputScratch : nil
            audioFramePublisher.send(AudioFrame(
                rmsIn: rmsIn,
                rmsOut: rmsOut,
                peakIn: peakIn,
                peakOut: peakOut,
                fftInDB: fftIn,
                fftOutDB: fftOut,
                sampleRate: sampleRate,
                telemetry: telemetry,
                timestamp: CACurrentMediaTime()
            ))
        }
    }

    // MARK: - Telemetry

    /// Snapshot the kernel's per-block telemetry slots into a name→value
    /// dict. Returns nil when the loaded preset doesn't declare any
    /// telemetry (the common case for legacy scripts), so consumers can
    /// short-circuit. Scalar slots come from a single FFI snapshot;
    /// vector slots are copied per-slot via `dsp_kernel_read_telemetry_vec`,
    /// which returns the live frame count for the most recent block.
    private func readTelemetry(kernel: DSPKernelRef) -> [String: TelemetryValue]? {
        refreshTelemetryNamesIfChanged(kernel: kernel)
        guard !telemetryNames.isEmpty else { return nil }

        // Staleness gate. When the audio thread hasn't ticked recently
        // (host paused, transport stopped, AU bypassed) the kernel's
        // telemetry ring keeps returning the last published value, so a
        // GR meter would freeze at whatever the compressor was doing the
        // moment audio stopped. Returning nil drops the telemetry field
        // from this frame; the UI's onFrame handler defaults its locals
        // (gr=0, grCurve=null) and the line snaps back to neutral.
        if CACurrentMediaTime() - lastRenderActivityTimestamp > Self.telemetryStaleThreshold {
            return nil
        }

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

    /// Re-read the kernel's telemetry metadata when it changes. Detected
    /// by comparing the metadata JSON string against the previously
    /// cached copy — the kernel rewrites this string on every script
    /// load, so any content change forces a re-parse. Parses on the
    /// display-link tick at most once per script load (rare).
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
        // Buffer must hold at least the full slot count so the FFI
        // snapshot can fill it; pad to 16 (the kernel TELEMETRY_LEN) so
        // we always pass a sensible capacity even if names trim short.
        let needed = max(telemetryNames.count, 16)
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

    // MARK: - Spectrogram Smoothing

    /// Symmetric per-bin smoother with a hard-step bypass, applied to the
    /// spectrogram-only columns. Two branches:
    ///   - **Hard-step bypass** (`|s - x| > 20` dB): `s = x`. Note-ons, note-offs,
    ///     and signal start/stop land in a single column with no tail.
    ///   - **Symmetric one-pole** (small step): `s = α·x + (1-α)·s` with α=0.15.
    ///     Converges toward the time-averaged magnitude, killing the
    ///     phase-dependent cross-term wobble that a Hann-windowed stationary
    ///     sine produces between hops in its sidelobe bins.
    ///
    /// Earlier asymmetric design (attack-snap + gentle-release) was insufficient:
    /// attack-snap fires on every upward step of a stationary wobble, leaving
    /// a ~1 dB residual oscillation that maps to ~3 magma indices in the
    /// bright sidelobe region — still visible as vertical stripes. Symmetric
    /// smoothing trades slightly slower fade-in onset (~3-frame time constant
    /// ≈ 65 ms at 46 cols/sec) for actual convergence to a uniform horizontal
    /// band on stationary tones.
    ///
    /// Cost: one subtract + one abs + one branch + (usually) two multiplies +
    /// one add per bin, twice per column. ~100k ops/sec at fftSize=2048,
    /// 46 cols/sec — negligible.
    private func applySpectrogramSmoothing(scratch: [Float], state: inout [Float]) {
        // α=0.15 chosen empirically: the deep-sidelobe cross-term wobble for
        // an off-bin sine through a Hann window can hit 5–8 dB peak-to-peak
        // in bins where the positive and negative image responses are
        // comparable. A one-pole at Nyquist alternation attenuates by
        // α/(2-α) — α=0.3 gives -15 dB (~1 dB residual on 8 dB input, still
        // visible); α=0.15 gives -22 dB (~0.5 dB residual, below one magma
        // index step under visualFloor=-90). Time constant is ~7 columns
        // ≈ 150 ms at 46 cols/sec — noticeable lag on dynamics but the
        // 20 dB bypass catches the loud-step cases that matter most.
        let alpha: Float = 0.15
        let oneMinusAlpha: Float = 1.0 - alpha
        let bypassThreshold: Float = 20.0
        let n = scratch.count
        guard state.count == n else { return }
        for i in 0..<n {
            let x = scratch[i]
            let s = state[i]
            if abs(s - x) > bypassThreshold {
                state[i] = x
            } else {
                state[i] = alpha * x + oneMinusAlpha * s
            }
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
