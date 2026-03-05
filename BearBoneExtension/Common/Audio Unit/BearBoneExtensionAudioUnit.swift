//
//  BearBoneExtensionAudioUnit.swift
//  BearBoneExtension
//
//  Created by Michael Jancsy on 2/25/26.
//

import AVFoundation
import Combine
import os.log

private let pluginLog = Logger(subsystem: "com.MichaelJancsy.BearBone", category: "DSP")

public class BearBoneExtensionAudioUnit: AUAudioUnit, @unchecked Sendable
{
	// Rust DSP kernel (opaque pointer)
	private var kernel: DSPKernelRef!

	/// Expose kernel reference for audio capture (spectrogram visualization).
	/// Only used by AudioCaptureManager on the UI thread.
	var kernelReference: DSPKernelRef? { kernel }

	// MARK: - Parameter Tree (8 fixed generic parameters, range 0–1)

	static let paramCount = 8

	private func buildParameterTree() {
		var params: [AUParameter] = []
		for i in 0..<Self.paramCount {
			let param = AUParameterTree.createParameter(
				withIdentifier: "param\(i)",
				name: "Param \(i)",
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

	// Cached path to bundled Python runtime for script reloads
	private var pythonHome: String?

	// Current script source (cached on successful reload, persisted in fullState)
	private var currentScriptSource: String?

	// Current script language (for fullState persistence and UI syncing)
	var currentScriptLanguage: ScriptLanguage = .python

	// Cached WASM bytes for Rust scripts (for instant fullState restore)
	private var currentWasmBytes: Data?

	/// The current Python script source, if one has been loaded via reloadScript or fullState.
	public var scriptSource: String? {
		return currentScriptSource
	}

	/// Publishes script source when it changes externally (preset selection, fullState restore).
	public let scriptSourceDidChange = PassthroughSubject<String, Never>()

	// Audio busses
	private var _inputBus: AUAudioUnitBus!
	private var _outputBus: AUAudioUnitBus!
	private var _inputBusses: AUAudioUnitBusArray!
	private var _outputBusses: AUAudioUnitBusArray!

	// Input buffer management (replaces C++ BufferedInputBus)
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

		buildParameterTree()

		// Load the bundled Python DSP script
		loadPythonScript()
	}

	private func loadPythonScript() {
		let bundle = Bundle(for: type(of: self))

		// Python home: the bundled Python standard library root
		// The bundle copies python-dist contents into Resources/python-dist/
		guard let pythonHome = bundle.path(forResource: "python-dist", ofType: nil) else {
			pluginLog.error("Bundled Python distribution not found in bundle, using Rust fallback DSP")
			return
		}
		self.pythonHome = pythonHome

		guard let scriptPath = bundle.path(forResource: "process", ofType: "py") else {
			pluginLog.error("process.py not found in bundle, using Rust fallback DSP")
			return
		}

		pluginLog.info("Loading Python script. pythonHome=\(pythonHome, privacy: .public) scriptPath=\(scriptPath, privacy: .public)")
		let success = dsp_kernel_load_script(kernel, pythonHome, scriptPath)
		if success {
			pluginLog.info("Python DSP script loaded successfully")

			// Warm-start: run process() a few times so any first-call allocations
			// (e.g. global buffer creation) happen before real audio arrives.
			// benchmark_process does 1 warm-up + 5 timed calls; it handles
			// the pre-allocateRenderResources state by creating temp arrays.
			let warmupTime = dsp_kernel_benchmark_process(kernel)
			if warmupTime >= 0 {
				pluginLog.info("Initial warm-up complete: \(warmupTime * 1000, privacy: .public)ms")
			}
		} else {
			if let errPtr = dsp_kernel_last_error(kernel) {
				let errMsg = String(cString: errPtr)
				pluginLog.error("Failed to load Python DSP script: \(errMsg, privacy: .public)")
			} else {
				pluginLog.error("Failed to load Python DSP script (no error details), using Rust fallback DSP")
			}
		}
	}

	/// Hot-reload a Python DSP script from source code.
	/// Writes the source to a temp file and calls dsp_kernel_load_script.
	/// On success, benchmarks the process function and returns timing info.
	public func reloadScript(source: String) -> (success: Bool, error: String?, processTimeMs: Double?, budgetMs: Double?) {
		guard let pythonHome = self.pythonHome else {
			return (false, "Python runtime not available", nil, nil)
		}

		let tempDir = FileManager.default.temporaryDirectory
		let tempFile = tempDir.appendingPathComponent("process_\(UUID().uuidString).py")

		do {
			try source.write(to: tempFile, atomically: true, encoding: .utf8)
		} catch {
			return (false, "Failed to write temp file: \(error.localizedDescription)", nil, nil)
		}

		defer {
			try? FileManager.default.removeItem(at: tempFile)
		}

		let success = dsp_kernel_load_script(kernel, pythonHome, tempFile.path)

		if success {
			currentScriptSource = source
			pluginLog.info("Python DSP script reloaded successfully")

			// Benchmark the process function
			let benchmarkSecs = dsp_kernel_benchmark_process(kernel)
			var processTimeMs: Double? = nil
			var budgetMs: Double? = nil

			if benchmarkSecs >= 0 {
				processTimeMs = benchmarkSecs * 1000.0
				let sampleRate = _outputBus.format.sampleRate
				let maxFrames = Double(dsp_kernel_get_max_frames(kernel))
				budgetMs = maxFrames / sampleRate * 1000.0
				pluginLog.info("Benchmark: \(processTimeMs!, privacy: .public)ms / \(budgetMs!, privacy: .public)ms budget")
			}

			return (true, nil, processTimeMs, budgetMs)
		} else {
			var errorMsg = "Unknown error"
			if let errPtr = dsp_kernel_last_error(kernel) {
				errorMsg = String(cString: errPtr)
			}
			pluginLog.error("Failed to reload Python DSP script: \(errorMsg, privacy: .public)")
			return (false, errorMsg, nil, nil)
		}
	}

	/// Load a pre-compiled WASM module into the DSP kernel.
	public func loadWasm(bytes: Data) -> (success: Bool, error: String?, processTimeMs: Double?, budgetMs: Double?) {
		let success = bytes.withUnsafeBytes { rawBuffer -> Bool in
			guard let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
				return false
			}
			return dsp_kernel_load_wasm(kernel, ptr, UInt32(bytes.count))
		}

		if success {
			pluginLog.info("WASM module loaded successfully")

			let benchmarkSecs = dsp_kernel_benchmark_process(kernel)
			var processTimeMs: Double? = nil
			var budgetMs: Double? = nil

			if benchmarkSecs >= 0 {
				processTimeMs = benchmarkSecs * 1000.0
				let sampleRate = _outputBus.format.sampleRate
				let maxFrames = Double(dsp_kernel_get_max_frames(kernel))
				budgetMs = maxFrames / sampleRate * 1000.0
				pluginLog.info("WASM benchmark: \(processTimeMs!, privacy: .public)ms / \(budgetMs!, privacy: .public)ms budget")
			}

			return (true, nil, processTimeMs, budgetMs)
		} else {
			var errorMsg = "Failed to load WASM module"
			if let errPtr = dsp_kernel_last_error(kernel) {
				errorMsg = String(cString: errPtr)
			}
			pluginLog.error("Failed to load WASM: \(errorMsg, privacy: .public)")
			return (false, errorMsg, nil, nil)
		}
	}

	/// Compile source code (detecting language) and load into the DSP kernel.
	/// For Python: direct load (sync). For Rust: compile to WASM, cache, then load.
	public func compileAndRun(source: String) async -> (success: Bool, error: String?, processTimeMs: Double?, budgetMs: Double?) {
		let language = ScriptLanguage.detect(from: source)

		switch language {
		case .python:
			let result = reloadScript(source: source)
			currentScriptLanguage = .python
			currentWasmBytes = nil
			return result

		case .rust:
			// Check cache first
			let cache = WasmCache()
			if let cachedWasm = cache.cachedWasm(for: source) {
				let result = loadWasm(bytes: cachedWasm)
				if result.success {
					currentScriptSource = source
					currentScriptLanguage = .rust
					currentWasmBytes = cachedWasm
				}
				return result
			}

			// Compile
			let compiler = RustCompiler()
			do {
				let wasmBytes = try await compiler.compile(source: source)
				cache.cache(wasm: wasmBytes, for: source)
				let result = loadWasm(bytes: wasmBytes)
				if result.success {
					currentScriptSource = source
					currentScriptLanguage = .rust
					currentWasmBytes = wasmBytes
				}
				return result
			} catch {
				return (false, error.localizedDescription, nil, nil)
			}
		}
	}

	// MARK: - License

	/// Verify a license serial key against the kernel's embedded public key.
	/// Returns true if valid (kernel is now in licensed state).
	func verifyLicense(_ serial: String) -> Bool {
		return dsp_kernel_verify_license(kernel, serial)
	}

	/// Check if kernel is currently licensed.
	func isLicensed() -> Bool {
		return dsp_kernel_is_licensed(kernel)
	}

	/// Get remaining demo seconds at current sample rate.
	func demoSecondsRemaining() -> Double {
		let sampleRate = _outputBus?.format.sampleRate ?? 48000.0
		return dsp_kernel_demo_seconds_remaining(kernel, sampleRate)
	}

	/// Reset the demo counter, giving another 60 seconds of demo time.
	func resetDemo() {
		dsp_kernel_reset_demo(kernel)
	}

	/// Set the licensed state directly (used by tests and license restore).
	func setLicensed(_ licensed: Bool) {
		dsp_kernel_set_licensed(kernel, licensed)
	}

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

	// MARK: - State Persistence

	private static let scriptSourceKey = "pythonScriptSource"
	private static let scriptLanguageKey = "scriptLanguage"
	private static let wasmBytesKey = "wasmBytes"

	public override var fullState: [String : Any]? {
		get {
			var state = super.fullState ?? [:]
			if let source = currentScriptSource,
			   let data = source.data(using: .utf8) {
				state[Self.scriptSourceKey] = data
			}
			state[Self.scriptLanguageKey] = currentScriptLanguage.rawValue
			if let wasmBytes = currentWasmBytes {
				state[Self.wasmBytesKey] = wasmBytes
			}
			return state
		}
		set {
			super.fullState = newValue
			guard let state = newValue,
				  let data = state[Self.scriptSourceKey] as? Data,
				  let source = String(data: data, encoding: .utf8) else {
				return
			}

			let languageRaw = state[Self.scriptLanguageKey] as? String ?? "python"
			let language = ScriptLanguage(rawValue: languageRaw) ?? .python

			switch language {
			case .python:
				let result = reloadScript(source: source)
				if result.success {
					scriptSourceDidChange.send(source)
				}

			case .rust:
				// Try to load cached WASM bytes directly (instant, no compilation)
				if let wasmBytes = state[Self.wasmBytesKey] as? Data {
					let result = loadWasm(bytes: wasmBytes)
					if result.success {
						currentScriptSource = source
						currentScriptLanguage = .rust
						currentWasmBytes = wasmBytes
						scriptSourceDidChange.send(source)
					}
				} else {
					// No cached WASM — just show the source, user must click Run
					currentScriptSource = source
					currentScriptLanguage = .rust
					scriptSourceDidChange.send(source)
				}
			}

			pluginLog.info("Restored \(language.rawValue) script from fullState (\(source.count) chars)")
		}
	}

	// MARK: - Preset Manager

	private var _presetManager: PresetManager?

	/// Preset manager for browsing, saving, and loading .py script presets.
	/// Created lazily on first access (requires @MainActor).
	@MainActor
	var presetManager: PresetManager {
		if _presetManager == nil {
			_presetManager = PresetManager(extensionBundle: Bundle(for: type(of: self)))
		}
		return _presetManager!
	}

	/// Load a preset into the DSP kernel and update preset manager state.
	/// Called from the UI when the user selects a preset from the browser.
	/// Both Python and Rust presets are compiled/loaded immediately.
	@MainActor
	func selectPreset(_ preset: Preset) async -> ScriptSaveResult {
		let pm = presetManager
		guard let source = pm.loadSource(for: preset) else {
			pluginLog.error("Failed to load preset source: \(preset.name, privacy: .public)")
			return ScriptSaveResult(success: false, error: "Failed to load preset source", processTimeMs: nil, budgetMs: nil)
		}

		// Always update preset manager and editor so the user can see the script
		pm.setCurrentPreset(preset, source: source)
		scriptSourceDidChange.send(source)

		let result = await compileAndRun(source: source)

		if result.success {
			// Sync DAW-facing currentPreset for factory presets
			if let factoryNumber = preset.factoryPresetNumber {
				let auPreset = AUAudioUnitPreset()
				auPreset.number = factoryNumber
				auPreset.name = preset.name
				_currentPreset = auPreset
			} else {
				_currentPreset = nil
			}
			pluginLog.info("Selected preset: \(preset.name, privacy: .public)")
		}

		return ScriptSaveResult(success: result.success, error: result.error, processTimeMs: result.processTimeMs, budgetMs: result.budgetMs)
	}

	// MARK: - Factory Presets

	public override var factoryPresets: [AUAudioUnitPreset]? {
		return FactoryPresetRegistry.entries.map { entry in
			let preset = AUAudioUnitPreset()
			preset.number = entry.number
			preset.name = entry.name
			return preset
		}
	}

	private var _currentPreset: AUAudioUnitPreset?

	public override var currentPreset: AUAudioUnitPreset? {
		get { return _currentPreset }
		set {
			_currentPreset = newValue
			guard let preset = newValue, preset.number >= 0 else { return }

			guard let entry = FactoryPresetRegistry.entries.first(where: { $0.number == preset.number }) else { return }

			let ext = entry.language == .rust ? "rs" : "py"
			let bundle = Bundle(for: type(of: self))
			guard let url = bundle.url(forResource: entry.resourceName, withExtension: ext),
				  let source = try? String(contentsOf: url, encoding: .utf8) else {
				pluginLog.error("Factory preset script not found: \(entry.resourceName).\(ext, privacy: .public)")
				return
			}

			switch entry.language {
			case .python:
				let result = reloadScript(source: source)
				if result.success {
					currentScriptLanguage = .python
					currentWasmBytes = nil
					scriptSourceDidChange.send(source)
					pluginLog.info("Loaded factory preset: \(entry.name, privacy: .public)")
				}
			case .rust:
				// Show source immediately, then compile async
				currentScriptSource = source
				currentScriptLanguage = .rust
				scriptSourceDidChange.send(source)
				pluginLog.info("Loaded Rust factory preset: \(entry.name, privacy: .public)")
				Task {
					let result = await self.compileAndRun(source: source)
					if !result.success {
						pluginLog.error("Failed to compile Rust factory preset: \(result.error ?? "unknown", privacy: .public)")
					}
				}
			}

			// Update preset manager if it exists (dispatch to main actor)
			if let pm = _presetManager {
				let presetNumber = preset.number
				Task { @MainActor in
					let factoryPreset = pm.presets.first { $0.factoryPresetNumber == presetNumber }
					pm.setCurrentPreset(factoryPreset, source: source)
				}
			}
		}
	}

	// MARK: - Render Resources

	public override func allocateRenderResources() throws {
		let inputChannelCount = inputBusses[0].format.channelCount
		let outputChannelCount = outputBusses[0].format.channelCount

		if outputChannelCount != inputChannelCount {
			setRenderResourcesAllocated(false)
			throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FailedInitialization), userInfo: nil)
		}

		// Allocate input buffer (replaces BufferedInputBus.allocateRenderResources)
		_maxFrames = self.maximumFramesToRender
		inputPCMBuffer = AVAudioPCMBuffer(pcmFormat: _inputBus.format, frameCapacity: _maxFrames)
		originalAudioBufferList = inputPCMBuffer?.audioBufferList
		mutableAudioBufferList = inputPCMBuffer?.mutableAudioBufferList

		dsp_kernel_initialize(kernel, Int32(inputChannelCount), Int32(outputChannelCount), _outputBus.format.sampleRate)

		try super.allocateRenderResources()
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

		// Capture self via Unmanaged to avoid ARC on the audio thread.
		// Buffer list pointers are nil until allocateRenderResources() is called,
		// but the framework may read this property before that.
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

			// Pull input (replaces BufferedInputBus.pullInput)
			guard let pullInputBlock = pullInputBlock else {
				return kAudioUnitErr_NoConnection
			}

			// Prepare input buffer list (replaces BufferedInputBus.prepareInputBufferList)
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

			// If passed null output buffer pointers, process in-place in the input buffer.
			for i in 0..<outABL.count {
				if outABL[i].mData == nil {
					outABL[i].mData = inABL[i].mData
				}
			}

			// Process with events (replaces AUProcessHelper.processWithEvents)
			let channelCount = UInt32(inABL.count)
			var now = AUEventSampleTime(timestamp.pointee.mSampleTime)
			var framesRemaining = frameCount
			var nextEvent = realtimeEventListHead

			while framesRemaining > 0 {
				if nextEvent == nil {
					// Process remaining frames
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

				// Handle all simultaneous events
				nextEvent = Self.performAllSimultaneousEvents(kernel: kernel, now: now, event: nextEvent!)
			}

			return noErr
		}
	}

	/// Call the Rust kernel to process a segment of audio.
	private static func callKernelProcess(
		kernel: DSPKernelRef,
		inABL: UnsafeMutableAudioBufferListPointer,
		outABL: UnsafeMutableAudioBufferListPointer,
		channelCount: UInt32,
		frameOffset: UInt32,
		frameCount: UInt32
	) {
		let count = Int(channelCount)

		// Build contiguous arrays of channel buffer pointers (optional to match C import)
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

	/// Walk the event linked list, handling all events at the current timestamp.
	/// Parameter events are dispatched to the Rust kernel; MIDI events are skipped.
	private static func performAllSimultaneousEvents(
		kernel: DSPKernelRef,
		now: AUEventSampleTime,
		event: UnsafePointer<AURenderEvent>
	) -> UnsafePointer<AURenderEvent>? {
		var current: UnsafePointer<AURenderEvent>? = event
		repeat {
			guard let evt = current else { break }

			// Handle parameter events from DAW automation
			if evt.pointee.head.eventType == .parameter {
				let paramEvent = evt.pointee.parameter
				dsp_kernel_set_parameter(kernel, paramEvent.parameterAddress, paramEvent.value)
			} else if evt.pointee.head.eventType == .parameterRamp {
				// For ramp events, apply the target value immediately
				// (sample-accurate ramping would require per-sample interpolation in the kernel)
				let paramEvent = evt.pointee.parameter
				dsp_kernel_set_parameter(kernel, paramEvent.parameterAddress, paramEvent.value)
			}

			// Advance to next event
			if let next = evt.pointee.head.next {
				current = UnsafeRawPointer(next).assumingMemoryBound(to: AURenderEvent.self)
			} else {
				current = nil
			}
		} while current != nil && current!.pointee.head.eventSampleTime <= now
		return current
	}

}
