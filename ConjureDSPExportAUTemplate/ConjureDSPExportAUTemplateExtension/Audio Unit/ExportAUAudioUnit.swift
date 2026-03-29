//
//  ExportAUAudioUnit.swift
//  ConjureDSPExportAUTemplateExtension
//
//  Minimal AUAudioUnit that loads a single WASM preset from its bundle Resources.
//  This is the template AU for ConjureDSP's "Export Preset as Standalone AUv3" feature.
//

import AVFoundation
import os.log

private let pluginLog = Logger(subsystem: "com.ConjureDSP-user.ExportTemplate", category: "DSP")

public class ExportAUAudioUnit: AUAudioUnit, @unchecked Sendable {
    // Rust DSP kernel (opaque pointer)
    private var kernel: DSPKernelRef!

    // Runtime configuration loaded from bundle
    private var config: RuntimeConfig?

    // True when a Python preset can't find its runtime (stdlib+numpy)
    private(set) var pythonRuntimeMissing = false

    // Audio busses
    private var _inputBus: AUAudioUnitBus!
    private var _outputBus: AUAudioUnitBus!
    private var _inputBusses: AUAudioUnitBusArray!
    private var _outputBusses: AUAudioUnitBusArray!

    // Input buffer management
    private var inputPCMBuffer: AVAudioPCMBuffer?
    private var originalAudioBufferList: UnsafePointer<AudioBufferList>?
    private var mutableAudioBufferList: UnsafeMutablePointer<AudioBufferList>?
    private var _maxFrames: AUAudioFrameCount = 0

    @objc override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions) throws {
        kernel = dsp_kernel_create()

        // Default to mono; host will negotiate the actual channel count.
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        try super.init(componentDescription: componentDescription, options: options)

        _inputBus = try AUAudioUnitBus(format: format)
        _inputBus.maximumChannelCount = 2

        _outputBus = try AUAudioUnitBus(format: format)
        _outputBus.maximumChannelCount = 2

        _inputBusses = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [_inputBus])
        _outputBusses = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [_outputBus])

        // Load runtime config
        let bundle = Bundle(for: type(of: self))
        config = RuntimeConfig.load(from: bundle)

        if let config = config {
            pluginLog.info("RuntimeConfig loaded: language=\(config.language, privacy: .public), preset=\(config.presetName, privacy: .public)")
        } else {
            pluginLog.warning("RuntimeConfig not found in bundle — defaulting to rust/wasm")
        }

        buildParameterTree()

        // Exported AUs run freely — no demo timer
        dsp_kernel_set_licensed(kernel, true)

        // Log shared Python runtime filesystem state (for debugging)
        // Use real home directory (not sandbox container) via getpwuid
        if let realHome = Self.realHomeDirectory() {
            let sharedPath = realHome + "/Library/Application Support/ConjureDSP/PythonRuntime-3.14"
            let libExists = FileManager.default.fileExists(atPath: sharedPath + "/lib/python3.14t")
            let dylibExists = FileManager.default.fileExists(atPath: sharedPath + "/lib/libpython3.14t.dylib")
            pluginLog.info("Shared runtime check: path=\(sharedPath, privacy: .public) lib=\(libExists, privacy: .public) dylib=\(dylibExists, privacy: .public)")
        }

        // Load preset from bundle (language determined by runtime-config.json)
        loadPresetFromBundle()
    }

    // MARK: - Parameter Tree

    private func buildParameterTree() {
        // Use rich metadata if available, otherwise fall back to generic 0–1 params
        if let metadata = config?.paramMetadata, !metadata.isEmpty {
            buildRichParameterTree(metadata: metadata)
        } else {
            buildGenericParameterTree()
        }
    }

    /// Build parameter tree with real ranges, units, and curve-aware normalize/denormalize.
    private func buildRichParameterTree(metadata: [ExportParamMetadata]) {
        let count = min(metadata.count, 16)
        var params: [AUParameter] = []
        let metadataRef = metadata

        for i in 0..<count {
            let meta = metadataRef[i]
            let auUnit: AudioUnitParameterUnit
            let valueStrings: [String]?
            if meta.isToggle {
                auUnit = .boolean
                valueStrings = nil
            } else if meta.isChoice, let opts = meta.options {
                auUnit = .indexed
                valueStrings = opts
            } else {
                auUnit = .generic
                valueStrings = nil
            }
            let param = AUParameterTree.createParameter(
                withIdentifier: "param\(i)",
                name: meta.name,
                address: AUParameterAddress(i),
                min: meta.min,
                max: meta.max,
                unit: auUnit,
                unitName: nil,
                flags: [.flag_IsReadable, .flag_IsWritable],
                valueStrings: valueStrings,
                dependentParameters: nil
            )
            param.value = meta.default
            params.append(param)
        }

        let tree = AUParameterTree.createTree(withChildren: params)
        let kernelRef = self.kernel!

        tree.implementorValueObserver = { param, value in
            let idx = Int(param.address)
            if idx < metadataRef.count {
                let normalized = metadataRef[idx].normalize(value)
                dsp_kernel_set_parameter(kernelRef, param.address, normalized)
            } else {
                dsp_kernel_set_parameter(kernelRef, param.address, value)
            }
        }

        tree.implementorValueProvider = { param in
            let normalized = dsp_kernel_get_parameter(kernelRef, param.address)
            let idx = Int(param.address)
            if idx < metadataRef.count {
                return metadataRef[idx].denormalize(normalized)
            }
            return normalized
        }

        tree.implementorStringFromValueCallback = { param, valuePtr in
            let value = valuePtr?.pointee ?? param.value
            let idx = Int(param.address)
            if idx < metadataRef.count {
                let meta = metadataRef[idx]
                if meta.isToggle {
                    return value >= 0.5 ? "On" : "Off"
                }
                if meta.isChoice, let opts = meta.options {
                    let choiceIdx = Int(value.rounded())
                    if choiceIdx >= 0, choiceIdx < opts.count {
                        return opts[choiceIdx]
                    }
                }
                return Self.formatParamValue(value, unit: meta.unit)
            }
            return String(format: "%.3f", value)
        }

        self.parameterTree = tree

        // Set kernel defaults (normalized, respects curve type)
        for (i, meta) in metadataRef.prefix(count).enumerated() {
            let normalized = meta.normalize(meta.default)
            dsp_kernel_set_parameter(kernelRef, UInt64(i), normalized)
        }
    }

    /// Build generic parameter tree with 0–1 range (legacy config without paramMetadata).
    private func buildGenericParameterTree() {
        let count = config?.effectiveParamCount ?? 8
        var params: [AUParameter] = []
        for i in 0..<count {
            let name = config?.paramLabel(at: i) ?? "Param \(i + 1)"
            let param = AUParameterTree.createParameter(
                withIdentifier: "param\(i)",
                name: name,
                address: AUParameterAddress(i),
                min: 0.0,
                max: 1.0,
                unit: .generic,
                unitName: nil,
                flags: [.flag_IsReadable, .flag_IsWritable],
                valueStrings: nil,
                dependentParameters: nil
            )
            param.value = 0.0
            params.append(param)
        }
        let tree = AUParameterTree.createTree(withChildren: params)
        let kernelRef = self.kernel!
        tree.implementorValueObserver = { param, value in
            dsp_kernel_set_parameter(kernelRef, param.address, value)
        }
        tree.implementorValueProvider = { param in
            return dsp_kernel_get_parameter(kernelRef, param.address)
        }
        tree.implementorStringFromValueCallback = { param, valuePtr in
            let value = valuePtr?.pointee ?? param.value
            return String(format: "%.3f", value)
        }
        self.parameterTree = tree
    }

    /// Format a parameter value with its unit string.
    static func formatParamValue(_ value: Float, unit: String) -> String {
        switch unit {
        case "dB":
            return String(format: "%.1f dB", value)
        case "Hz":
            if value >= 1000 { return String(format: "%.2f kHz", value / 1000) }
            return String(format: "%.1f Hz", value)
        case "ms":
            if value >= 1000 { return String(format: "%.2f s", value / 1000) }
            return String(format: "%.1f ms", value)
        case "%":
            return String(format: "%.0f%%", value)
        case ":1":
            return String(format: "%.1f:1", value)
        case "":
            return String(format: "%.3f", value)
        default:
            return String(format: "%.2f %@", value, unit)
        }
    }

    // MARK: - Preset Loading

    private func loadPresetFromBundle() {
        let bundle = Bundle(for: type(of: self))
        let language = config?.language ?? "rust"

        switch language {
        case "python":
            loadPythonPreset(from: bundle)
        default:
            loadWasmPreset(from: bundle)
        }
    }

    private func loadWasmPreset(from bundle: Bundle) {
        guard let wasmURL = bundle.url(forResource: "preset", withExtension: "wasm"),
              let wasmData = try? Data(contentsOf: wasmURL) else {
            pluginLog.error("preset.wasm not found in bundle")
            return
        }

        let success = wasmData.withUnsafeBytes { rawBuffer -> Bool in
            guard let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return false
            }
            return dsp_kernel_load_wasm(kernel, ptr, UInt32(wasmData.count))
        }

        if success {
            pluginLog.info("WASM preset loaded successfully")
            warmStart()
        } else {
            logKernelError("Failed to load WASM preset")
        }
    }

    private func loadPythonPreset(from bundle: Bundle) {
        guard let presetPath = bundle.path(forResource: "preset", ofType: "py") else {
            pluginLog.error("preset.py not found in bundle")
            return
        }

        guard let pythonHome = findPythonHome(bundle: bundle) else {
            pluginLog.error("Python runtime not found — preset will not process audio")
            pythonRuntimeMissing = true
            return
        }

        pluginLog.info("Loading Python preset. pythonHome=\(pythonHome, privacy: .public)")
        let success = dsp_kernel_load_script(kernel, pythonHome, presetPath)

        if success {
            pluginLog.info("Python preset loaded successfully")
            warmStart()
        } else {
            logKernelError("Failed to load Python preset")
        }
    }

    // MARK: - Python Runtime Resolution

    /// Searches for a Python runtime in order: own bundle, App Group container,
    /// legacy shared location, environment variable.
    private func findPythonHome(bundle: Bundle) -> String? {
        // 1. Own bundle (standalone/full export)
        pluginLog.info("findPythonHome: checking bundle at \(bundle.bundlePath, privacy: .public)")
        if let bundled = bundle.path(forResource: "python-dist", ofType: nil) {
            pluginLog.info("findPythonHome: found Python runtime in bundle")
            return bundled
        }
        pluginLog.info("findPythonHome: no bundled python-dist found")

        // 2. App Group container (provisioned by ConjureDSPTerminal)
        // Exported AUs don't have the App Group entitlement, so use the raw filesystem path.
        if let realHome = Self.realHomeDirectory() {
            let appGroup = realHome + "/Library/Group Containers/group.com.MichaelJancsy.ConjureDSP/PythonRuntime"
            pluginLog.info("findPythonHome: checking App Group container at \(appGroup, privacy: .public)")
            if FileManager.default.fileExists(atPath: appGroup + "/lib/python3.14t") {
                pluginLog.info("findPythonHome: found Python runtime in App Group container")
                return appGroup
            }
            pluginLog.info("findPythonHome: App Group container missing or no lib/python3.14t")

            // 3. Legacy shared location (backward compatibility)
            let legacy = realHome + "/Library/Application Support/ConjureDSP/PythonRuntime-3.14"
            pluginLog.info("findPythonHome: checking legacy location at \(legacy, privacy: .public)")
            if FileManager.default.fileExists(atPath: legacy + "/lib/python3.14t") {
                pluginLog.info("findPythonHome: found Python runtime at legacy location")
                return legacy
            }
            pluginLog.info("findPythonHome: legacy location missing or no lib/python3.14t")
        } else {
            pluginLog.warning("findPythonHome: could not resolve real home directory")
        }

        // 4. Environment variable override (power users)
        if let envPath = ProcessInfo.processInfo.environment["CONJUREDSP_PYTHON_HOME"],
           FileManager.default.fileExists(atPath: envPath) {
            pluginLog.info("findPythonHome: found Python runtime via CONJUREDSP_PYTHON_HOME")
            return envPath
        }
        pluginLog.info("findPythonHome: no CONJUREDSP_PYTHON_HOME set or path does not exist")

        return nil
    }

    // MARK: - Helpers

    /// Returns the real home directory path, bypassing sandbox container redirection.
    /// Uses `getpwuid(getuid())` which returns the actual user home (e.g. `/Users/michael`)
    /// even when running inside an App Sandbox container.
    private static func realHomeDirectory() -> String? {
        guard let pw = getpwuid(getuid()), let homeDir = pw.pointee.pw_dir else {
            return nil
        }
        return String(cString: homeDir)
    }

    private func warmStart() {
        let warmupTime = dsp_kernel_benchmark_process(kernel)
        if warmupTime >= 0 {
            pluginLog.info("Warm-up complete: \(warmupTime * 1000, privacy: .public)ms")
        }
    }

    private func logKernelError(_ prefix: String) {
        if let errPtr = dsp_kernel_last_error(kernel) {
            let errMsg = String(cString: errPtr)
            pluginLog.error("\(prefix, privacy: .public): \(errMsg, privacy: .public)")
        } else {
            pluginLog.error("\(prefix, privacy: .public)")
        }
    }

    // MARK: - Lifecycle

    deinit {
        if let kernel = kernel {
            dsp_kernel_destroy(kernel)
        }
    }

    public override var inputBusses: AUAudioUnitBusArray {
        return _inputBusses
    }

    public override var outputBusses: AUAudioUnitBusArray {
        return _outputBusses
    }

    /// Algorithmic latency for DAW delay compensation.
    /// Reads from runtime-config.json (set at export time), falling back to kernel FFI.
    public override var latency: TimeInterval {
        let samples = config?.latencySamples ?? dsp_kernel_latency_samples(kernel)
        let sr = _outputBusses[0].format.sampleRate
        guard sr > 0 else { return 0 }
        return TimeInterval(samples) / sr
    }

    public override var channelCapabilities: [NSNumber] {
        return [NSNumber(value: 1), NSNumber(value: 1),
                NSNumber(value: 2), NSNumber(value: 2)]
    }

    public override var maximumFramesToRender: AUAudioFrameCount {
        get { dsp_kernel_get_max_frames(kernel) }
        set { dsp_kernel_set_max_frames(kernel, newValue) }
    }

    public override var shouldBypassEffect: Bool {
        get { dsp_kernel_is_bypassed(kernel) }
        set { dsp_kernel_set_bypassed(kernel, newValue) }
    }

    // MARK: - Render Resources

    public override func allocateRenderResources() throws {
        let inputChannelCount = inputBusses[0].format.channelCount
        let outputChannelCount = outputBusses[0].format.channelCount

        if outputChannelCount != inputChannelCount {
            setRenderResourcesAllocated(false)
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FailedInitialization), userInfo: nil)
        }

        _maxFrames = self.maximumFramesToRender
        inputPCMBuffer = AVAudioPCMBuffer(pcmFormat: _inputBus.format, frameCapacity: _maxFrames)
        originalAudioBufferList = inputPCMBuffer?.audioBufferList
        mutableAudioBufferList = inputPCMBuffer?.mutableAudioBufferList

        dsp_kernel_initialize(kernel, Int32(inputChannelCount), Int32(outputChannelCount), _outputBus.format.sampleRate)
        pluginLog.info("allocateRenderResources: channels=\(inputChannelCount, privacy: .public), sampleRate=\(self._outputBus.format.sampleRate, privacy: .public)")

        try super.allocateRenderResources()

        // Check for kernel errors shortly after rendering begins
        let kernelRef = self.kernel!
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if let errPtr = dsp_kernel_last_error(kernelRef) {
                let msg = String(cString: errPtr)
                pluginLog.error("Post-render kernel error: \(msg, privacy: .public)")
            } else {
                pluginLog.info("Post-render check: no kernel errors")
            }
        }
    }

    public override func deallocateRenderResources() {
        dsp_kernel_deinitialize(kernel)
        inputPCMBuffer = nil
        originalAudioBufferList = nil
        mutableAudioBufferList = nil
        super.deallocateRenderResources()
    }

    // MARK: - Rendering

    public override var internalRenderBlock: AUInternalRenderBlock {
        let kernel = self.kernel!
        let unmanagedSelf = Unmanaged.passUnretained(self)

        return { actionFlags, timestamp, frameCount, outputBusNumber,
                 outputData, realtimeEventListHead, pullInputBlock in

            let au = unmanagedSelf.takeUnretainedValue()
            guard let originalABL = au.originalAudioBufferList,
                  let mutableABL = au.mutableAudioBufferList else {
                return kAudioUnitErr_Uninitialized
            }
            let maxFrames = au._maxFrames

            guard frameCount <= dsp_kernel_get_max_frames(kernel) else {
                return kAudioUnitErr_TooManyFramesToProcess
            }

            guard let pullInputBlock = pullInputBlock else {
                return kAudioUnitErr_NoConnection
            }

            // Prepare input buffer list
            let byteSize = min(frameCount, maxFrames) * UInt32(MemoryLayout<Float>.size)
            let mutableBufList = UnsafeMutableAudioBufferListPointer(mutableABL)
            let origBufList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: originalABL))
            mutableABL.pointee.mNumberBuffers = originalABL.pointee.mNumberBuffers
            for i in 0..<origBufList.count {
                mutableBufList[i].mNumberChannels = origBufList[i].mNumberChannels
                mutableBufList[i].mData = origBufList[i].mData
                mutableBufList[i].mDataByteSize = byteSize
            }

            var pullFlags = AudioUnitRenderActionFlags(rawValue: 0)
            let err = pullInputBlock(&pullFlags, timestamp, frameCount, 0, mutableABL)
            guard err == noErr else { return err }

            let inABL = UnsafeMutableAudioBufferListPointer(mutableABL)
            let outABL = UnsafeMutableAudioBufferListPointer(outputData)

            // If passed null output buffer pointers, process in-place.
            for i in 0..<outABL.count {
                if outABL[i].mData == nil {
                    outABL[i].mData = inABL[i].mData
                }
            }

            // Query host musical context and transport state for BPM sync.
            var tempo: Double = 0
            var timeSigNumerator: Double = 0
            var timeSigDenominator: Int = 0
            var beatPosition: Double = 0
            if let musicalContext = au.musicalContextBlock {
                var downbeatPosition: Double = 0
                var sampleOffsetToNextBeat: Int = 0
                musicalContext(&tempo, &timeSigNumerator, &timeSigDenominator,
                               &beatPosition, &sampleOffsetToNextBeat, &downbeatPosition)
            }

            var transportIsPlaying = false
            var samplePosition: Double = 0
            if let transportState = au.transportStateBlock {
                var transportFlags: AUHostTransportStateFlags = []
                var currentSamplePosition: Double = 0
                var cycleStart: Double = 0
                var cycleEnd: Double = 0
                transportState(&transportFlags, &currentSamplePosition, &cycleStart, &cycleEnd)
                transportIsPlaying = transportFlags.contains(.moving)
                samplePosition = currentSamplePosition
            }

            dsp_kernel_set_transport(kernel, tempo, beatPosition, transportIsPlaying,
                                     Int32(timeSigNumerator), Int32(timeSigDenominator),
                                     samplePosition)

            // Process with events
            let channelCount = UInt32(inABL.count)
            var now = AUEventSampleTime(timestamp.pointee.mSampleTime)
            var framesRemaining = frameCount
            var nextEvent = realtimeEventListHead

            while framesRemaining > 0 {
                if nextEvent == nil {
                    let frameOffset = frameCount - framesRemaining
                    Self.callKernelProcess(kernel: kernel, inABL: inABL, outABL: outABL,
                                           channelCount: channelCount, frameOffset: frameOffset,
                                           frameCount: framesRemaining)
                    return noErr
                }

                let headEventTime = nextEvent!.pointee.head.eventSampleTime
                let framesThisSegment = UInt32(max(0, headEventTime - now))

                if framesThisSegment > 0 {
                    let frameOffset = frameCount - framesRemaining
                    Self.callKernelProcess(kernel: kernel, inABL: inABL, outABL: outABL,
                                           channelCount: channelCount, frameOffset: frameOffset,
                                           frameCount: framesThisSegment)
                    framesRemaining -= framesThisSegment
                    now += AUEventSampleTime(framesThisSegment)
                }

                nextEvent = Self.performAllSimultaneousEvents(kernel: kernel, now: now, event: nextEvent!)
            }

            return noErr
        }
    }

    private static func callKernelProcess(
        kernel: DSPKernelRef,
        inABL: UnsafeMutableAudioBufferListPointer,
        outABL: UnsafeMutableAudioBufferListPointer,
        channelCount: UInt32,
        frameOffset: UInt32,
        frameCount: UInt32
    ) {
        let count = Int(channelCount)

        var inputPtrs = [UnsafePointer<Float>?]()
        inputPtrs.reserveCapacity(count)
        var outputPtrs = [UnsafeMutablePointer<Float>?]()
        outputPtrs.reserveCapacity(count)

        for ch in 0..<count {
            let baseIn = inABL[ch].mData!.assumingMemoryBound(to: Float.self)
            inputPtrs.append(UnsafePointer(baseIn.advanced(by: Int(frameOffset))))

            let baseOut = outABL[ch].mData!.assumingMemoryBound(to: Float.self)
            outputPtrs.append(baseOut.advanced(by: Int(frameOffset)))
        }

        inputPtrs.withUnsafeBufferPointer { inBuf in
            outputPtrs.withUnsafeBufferPointer { outBuf in
                dsp_kernel_process(kernel, inBuf.baseAddress!, outBuf.baseAddress!, channelCount, frameCount)
            }
        }
    }

    private static func performAllSimultaneousEvents(
        kernel: DSPKernelRef,
        now: AUEventSampleTime,
        event: UnsafePointer<AURenderEvent>
    ) -> UnsafePointer<AURenderEvent>? {
        var current: UnsafePointer<AURenderEvent>? = event
        repeat {
            guard let evt = current else { break }

            if evt.pointee.head.eventType == .parameter {
                let paramEvent = evt.pointee.parameter
                dsp_kernel_set_parameter(kernel, paramEvent.parameterAddress, paramEvent.value)
            } else if evt.pointee.head.eventType == .parameterRamp {
                let paramEvent = evt.pointee.parameter
                dsp_kernel_set_parameter(kernel, paramEvent.parameterAddress, paramEvent.value)
            }

            if let next = evt.pointee.head.next {
                current = UnsafeRawPointer(next).assumingMemoryBound(to: AURenderEvent.self)
            } else {
                current = nil
            }
        } while current != nil && current!.pointee.head.eventSampleTime <= now
        return current
    }
}
