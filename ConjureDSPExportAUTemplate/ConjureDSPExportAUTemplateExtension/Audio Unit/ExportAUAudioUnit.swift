//
//  ExportAUAudioUnit.swift
//  ConjureDSPExportAUTemplateExtension
//
//  Minimal AUAudioUnit that loads a single WASM preset from its bundle Resources.
//  This is the template AU for ConjureDSP's "Export Preset as Standalone AUv3" feature.
//

import AVFoundation
import Darwin.Mach
import os.log

private let pluginLog = Logger(subsystem: "com.ConjureDSP-user.ExportTemplate", category: "DSP")

public class ExportAUAudioUnit: AUAudioUnit, @unchecked Sendable {
    // Rust DSP kernel (opaque pointer)
    private var kernel: DSPKernelRef!

    // Runtime configuration loaded from bundle
    private var config: RuntimeConfig?

    // True when a Python preset can't find its runtime (stdlib+numpy)
    private(set) var pythonRuntimeMissing = false

    // Non-nil when the preset failed to load; audio passes through unchanged
    private(set) var loadError: String?

    // MARK: - Debug logging & render stats
    //
    // These are owned by the AU (not the view) so they persist across view
    // re-creation by the DAW. The debug pane in ExportAUMainView binds to
    // `debugLog` and polls `renderStats.snapshot()` at 1 Hz.

    /// In-memory event log. Main-thread only; see ExportDebugLog.
    let debugLog = ExportDebugLog()

    /// Audio-thread-safe render statistics.
    let renderStats = RenderStats()

    /// Static plugin identity snapshot built at the end of init. Read by
    /// the debug pane and not mutated after init.
    private(set) var pluginInfo: PluginInfo = .empty

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

        trace(.info, "config", "AU init — bundle=\(bundle.bundlePath)")

        if let config = config {
            trace(.info, "config",
                  "runtime-config loaded: language=\(config.language) preset=\(config.presetName) params=\(config.effectiveParamCount) latency=\(config.latencySamples ?? 0)")
        } else {
            trace(.warning, "config", "runtime-config.json not found in bundle — defaulting to rust/wasm")
        }

        buildParameterTree()

        // Exported AUs run freely — no demo timer
        dsp_kernel_set_licensed(kernel, true)

        // Load preset from bundle (language determined by runtime-config.json)
        loadPresetFromBundle()

        // Build the static plugin-info snapshot for the debug pane.
        buildPluginInfo(bundle: bundle)
    }

    // MARK: - trace helper

    /// Main-thread-only logging that fans out to both os.log (via pluginLog,
    /// preserving `privacy: .public` semantics) and the in-memory debug log
    /// (rendered plain-string copy for the debug pane).
    private func trace(_ level: ExportDebugLog.Level, _ category: String, _ message: String) {
        switch level {
        case .debug:
            pluginLog.debug("[\(category, privacy: .public)] \(message, privacy: .public)")
        case .info:
            pluginLog.info("[\(category, privacy: .public)] \(message, privacy: .public)")
        case .warning:
            pluginLog.warning("[\(category, privacy: .public)] \(message, privacy: .public)")
        case .error:
            pluginLog.error("[\(category, privacy: .public)] \(message, privacy: .public)")
        }
        if Thread.isMainThread {
            debugLog.append(level: level, category: category, message: message)
        } else {
            // Hop to main — preserves ordering because DispatchQueue.main is a
            // serial queue. All current callers are already on main, so this
            // branch is effectively dead code but keeps the contract safe.
            DispatchQueue.main.async { [debugLog] in
                debugLog.append(level: level, category: category, message: message)
            }
        }
    }

    // MARK: - Plugin info snapshot

    private func buildPluginInfo(bundle: Bundle) {
        let desc = self.componentDescription
        let subtype = fourCharString(desc.componentSubType)
        let manufacturer = fourCharString(desc.componentManufacturer)
        self.pluginInfo = PluginInfo(
            presetName: config?.presetName ?? "ConjureDSP Export",
            language: config?.language ?? "rust",
            subtype: subtype,
            manufacturer: manufacturer,
            bundlePath: bundle.bundlePath,
            runtimeConfigFound: config != nil,
            paramCount: config?.effectiveParamCount ?? 8,
            latencySamples: config?.latencySamples ?? 0,
            pythonHome: resolvedPythonHome,
            namModelFile: config?.namModelFile
        )
    }

    /// Cache of the Python home resolved during init, if any, for PluginInfo.
    private var resolvedPythonHome: String?

    private func fourCharString(_ code: OSType) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }

    // MARK: - Parameter Tree

    private func buildParameterTree() {
        // Use rich metadata if available, otherwise fall back to generic 0–1 params
        if let metadata = config?.paramMetadata, !metadata.isEmpty {
            buildRichParameterTree(metadata: metadata)
            trace(.info, "params", "built rich parameter tree (\(min(metadata.count, 16)) params)")
        } else {
            buildGenericParameterTree()
            let count = config?.effectiveParamCount ?? 8
            trace(.info, "params", "built generic parameter tree (\(count) params, 0–1 range)")
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
            } else if meta.isInteger {
                // .indexed without valueStrings tells hosts the parameter is
                // discrete-stepped (integer-valued) but should still display
                // the numeric value with its unit instead of an enum label.
                auUnit = .indexed
                valueStrings = nil
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
                return Self.formatParamValue(value, unit: meta.unit, isInteger: meta.isInteger)
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
        return formatParamValue(value, unit: unit, isInteger: false)
    }

    /// Format a parameter value with its unit string. When `isInteger` is true,
    /// the value is rounded to the nearest whole number and rendered without
    /// any decimal places (e.g., `"4 bits"`, `"3 x"`, or `"4"` when unit is empty).
    static func formatParamValue(_ value: Float, unit: String, isInteger: Bool) -> String {
        if isInteger {
            let intVal = Int(value.rounded())
            if unit.isEmpty {
                return "\(intVal)"
            }
            return "\(intVal) \(unit)"
        }
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
            trace(.error, "preset.wasm", "preset.wasm not found in bundle")
            loadError = "preset.wasm not found in bundle"
            return
        }

        trace(.info, "preset.wasm", "loading WASM preset (\(wasmData.count) bytes) from \(wasmURL.lastPathComponent)")

        let success = wasmData.withUnsafeBytes { rawBuffer -> Bool in
            guard let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return false
            }
            return dsp_kernel_load_wasm(kernel, ptr, UInt32(wasmData.count))
        }

        if success {
            trace(.info, "preset.wasm", "WASM preset loaded successfully")
            // Inject embedded NAM model if present
            injectEmbeddedNamModel(from: bundle)
            warmStart()
        } else {
            let err = kernelErrorString() ?? "Failed to load preset"
            trace(.error, "preset.wasm", "dsp_kernel_load_wasm failed: \(err)")
            loadError = err
        }
    }

    private func loadPythonPreset(from bundle: Bundle) {
        guard let presetPath = bundle.path(forResource: "preset", ofType: "py") else {
            trace(.error, "preset.python", "preset.py not found in bundle")
            loadError = "preset.py not found in bundle"
            return
        }

        let presetSize = (try? FileManager.default.attributesOfItem(atPath: presetPath)[.size] as? NSNumber)?.intValue ?? -1
        trace(.info, "preset.python", "loading Python preset from \(presetPath) (\(presetSize) bytes)")

        guard let pythonHome = findPythonHome(bundle: bundle) else {
            trace(.error, "python.home", "Python runtime not found — preset will not process audio")
            pythonRuntimeMissing = true
            return
        }
        resolvedPythonHome = pythonHome

        // Set tones directory to bundle Resources so embedded model.nam is found
        // by conjuredsp.nam's path resolution (tone3000:// or relative "model.nam")
        if config?.namModelFile != nil,
           let resourcesPath = bundle.resourcePath {
            dsp_kernel_set_tones_dir(kernel, resourcesPath)
            trace(.info, "nam", "set tones dir to bundle resources for Python NAM lookup: \(resourcesPath)")
        }

        trace(.info, "preset.python", "calling dsp_kernel_load_script (pythonHome=\(pythonHome))")
        let success = dsp_kernel_load_script(kernel, pythonHome, presetPath)

        if success {
            trace(.info, "preset.python", "Python preset loaded successfully")
            warmStart()
        } else {
            let err = kernelErrorString() ?? "Failed to load preset"
            trace(.error, "preset.python", "dsp_kernel_load_script failed: \(err)")
            loadError = err
        }
    }

    /// Load and inject an embedded .nam model file from the bundle Resources.
    /// For WASM presets, reads the .nam JSON, serializes to binary protocol,
    /// and calls dsp_kernel_inject_nam().
    private func injectEmbeddedNamModel(from bundle: Bundle) {
        guard let namFileName = config?.namModelFile else { return }

        let namBaseName = (namFileName as NSString).deletingPathExtension
        let namExt = (namFileName as NSString).pathExtension

        trace(.info, "nam", "looking for embedded NAM model: \(namFileName)")

        guard let namURL = bundle.url(forResource: namBaseName, withExtension: namExt.isEmpty ? "nam" : namExt),
              let namData = try? Data(contentsOf: namURL) else {
            trace(.warning, "nam", "embedded NAM model '\(namFileName)' not found in bundle")
            return
        }

        trace(.info, "nam", "loaded NAM model file (\(namData.count) bytes)")

        // Parse .nam JSON and serialize to binary protocol for WASM injection
        guard let namJson = try? JSONSerialization.jsonObject(with: namData) as? [String: Any],
              let architecture = namJson["architecture"] as? String,
              let configObj = namJson["config"],
              let weightsArray = namJson["weights"] as? [Double] else {
            trace(.error, "nam", "failed to parse embedded .nam file")
            return
        }

        let arch: UInt32 = architecture == "LSTM" ? 1 : 0
        let sampleRate = Float((namJson["sample_rate"] as? Double) ?? (namJson["sample_rate"] as? Int).map(Double.init) ?? 48000.0)

        // Serialize config JSON
        guard let configData = try? JSONSerialization.data(withJSONObject: configObj) else {
            trace(.error, "nam", "failed to serialize NAM config JSON")
            return
        }

        // Build binary protocol
        var binary = Data()
        var archLE = arch.littleEndian
        binary.append(Data(bytes: &archLE, count: 4))
        var srLE = sampleRate.bitPattern.littleEndian
        binary.append(Data(bytes: &srLE, count: 4))
        var configLen = UInt32(configData.count).littleEndian
        binary.append(Data(bytes: &configLen, count: 4))
        binary.append(configData)
        var weightCount = UInt32(weightsArray.count).littleEndian
        binary.append(Data(bytes: &weightCount, count: 4))
        for w in weightsArray {
            var f = Float(w).bitPattern.littleEndian
            binary.append(Data(bytes: &f, count: 4))
        }

        let success = binary.withUnsafeBytes { rawBuffer -> Bool in
            guard let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return false
            }
            return dsp_kernel_inject_nam(kernel, ptr, UInt(binary.count))
        }

        if success {
            trace(.info, "nam", "injected embedded NAM model (\(binary.count) bytes, arch=\(architecture), sr=\(sampleRate))")
        } else {
            trace(.error, "nam", "failed to inject embedded NAM model (dsp_kernel_inject_nam returned false)")
        }
    }

    // MARK: - Python Runtime Resolution

    /// Searches for a Python runtime in order: own bundle, App Group container,
    /// environment variable.
    private func findPythonHome(bundle: Bundle) -> String? {
        // 1. Own bundle (standalone/full export)
        trace(.info, "python.home", "checking bundle at \(bundle.bundlePath)")
        if let bundled = bundle.path(forResource: "python-dist", ofType: nil) {
            trace(.info, "python.home", "found Python runtime in bundle: \(bundled)")
            return bundled
        }
        trace(.info, "python.home", "no bundled python-dist found")

        // 2. App Group container (provisioned by ConjureDSPTerminal)
        // Use the raw filesystem path — the sandbox exception in the entitlements grants
        // read access to ~/Library/Group Containers/group.com.MichaelJancsy.ConjureDSP/PythonRuntime/.
        // Use isReadableFile (not fileExists) — fileExists uses stat() which may succeed even
        // when the sandbox blocks actual reads, causing Python's Py_Initialize() to call
        // Py_FatalError() and abort the process when it can't open its stdlib.
        if let realHome = Self.realHomeDirectory() {
            let appGroup = realHome + "/Library/Group Containers/group.com.MichaelJancsy.ConjureDSP/PythonRuntime"
            trace(.info, "python.home", "checking App Group container at \(appGroup)")
            if FileManager.default.isReadableFile(atPath: appGroup + "/lib/python3.14t/os.py") {
                trace(.info, "python.home", "found Python runtime in App Group container")
                return appGroup
            }
            trace(.info, "python.home", "App Group container missing or not readable")
        } else {
            trace(.warning, "python.home", "could not resolve real home directory")
        }

        // 3. Environment variable override (power users)
        if let envPath = ProcessInfo.processInfo.environment["CONJUREDSP_PYTHON_HOME"],
           FileManager.default.fileExists(atPath: envPath) {
            trace(.info, "python.home", "found Python runtime via CONJUREDSP_PYTHON_HOME=\(envPath)")
            return envPath
        }
        trace(.info, "python.home", "no CONJUREDSP_PYTHON_HOME set or path does not exist")

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
            trace(.info, "warmup", "warm-up complete: \(String(format: "%.3f", warmupTime * 1000))ms")
        }
    }

    /// Returns the current kernel error, if any. Safe to call from any thread.
    func currentKernelError() -> String? {
        kernelErrorString()
    }

    private func kernelErrorString() -> String? {
        guard let errPtr = dsp_kernel_last_error(kernel) else { return nil }
        return String(cString: errPtr)
    }

    private func logKernelError(_ prefix: String) {
        if let errMsg = kernelErrorString() {
            trace(.error, "render.error", "\(prefix): \(errMsg)")
        } else {
            trace(.error, "render.error", prefix)
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

        let sr = _outputBus.format.sampleRate
        dsp_kernel_initialize(kernel, Int32(inputChannelCount), Int32(outputChannelCount), sr)
        renderStats.sampleRate = sr
        let latencySamples = config?.latencySamples ?? dsp_kernel_latency_samples(kernel)
        trace(.info, "allocate",
              "channels=\(inputChannelCount) sampleRate=\(sr) maxFrames=\(_maxFrames) latency=\(latencySamples) samples")

        try super.allocateRenderResources()

        // Check for kernel errors shortly after rendering begins
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            if let errPtr = dsp_kernel_last_error(self.kernel) {
                let msg = String(cString: errPtr)
                self.trace(.error, "render.error", "post-render kernel error: \(msg)")
            } else {
                self.trace(.info, "render.error", "post-render check: no kernel errors")
            }
        }
    }

    public override func deallocateRenderResources() {
        dsp_kernel_deinitialize(kernel)
        inputPCMBuffer = nil
        originalAudioBufferList = nil
        mutableAudioBufferList = nil
        super.deallocateRenderResources()
        trace(.info, "deallocate", "render resources released")
    }

    // MARK: - Rendering

    public override var internalRenderBlock: AUInternalRenderBlock {
        let kernel = self.kernel!
        let unmanagedSelf = Unmanaged.passUnretained(self)
        let unmanagedStats = Unmanaged.passUnretained(self.renderStats)

        return { actionFlags, timestamp, frameCount, outputBusNumber,
                 outputData, realtimeEventListHead, pullInputBlock in

            let au = unmanagedSelf.takeUnretainedValue()
            let stats = unmanagedStats.takeUnretainedValue()
            let blockStartTime = mach_absolute_time()

            guard let originalABL = au.originalAudioBufferList,
                  let mutableABL = au.mutableAudioBufferList else {
                stats.recordRender(
                    startMachTime: blockStartTime,
                    endMachTime: mach_absolute_time(),
                    frames: UInt64(frameCount),
                    dropout: true
                )
                return kAudioUnitErr_Uninitialized
            }
            let maxFrames = au._maxFrames

            guard frameCount <= dsp_kernel_get_max_frames(kernel) else {
                stats.recordRender(
                    startMachTime: blockStartTime,
                    endMachTime: mach_absolute_time(),
                    frames: UInt64(frameCount),
                    dropout: true
                )
                return kAudioUnitErr_TooManyFramesToProcess
            }

            guard let pullInputBlock = pullInputBlock else {
                stats.recordRender(
                    startMachTime: blockStartTime,
                    endMachTime: mach_absolute_time(),
                    frames: UInt64(frameCount),
                    dropout: true
                )
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
            guard err == noErr else {
                stats.recordRender(
                    startMachTime: blockStartTime,
                    endMachTime: mach_absolute_time(),
                    frames: UInt64(frameCount),
                    dropout: true
                )
                return err
            }

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
                    stats.recordRender(
                        startMachTime: blockStartTime,
                        endMachTime: mach_absolute_time(),
                        frames: UInt64(frameCount),
                        dropout: false
                    )
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

            stats.recordRender(
                startMachTime: blockStartTime,
                endMachTime: mach_absolute_time(),
                frames: UInt64(frameCount),
                dropout: false
            )
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
