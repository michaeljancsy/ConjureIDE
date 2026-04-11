//
//  ConjureDSPExtensionAudioUnit.swift
//  ConjureDSPExtension
//
//  Created by Michael Jancsy on 2/25/26.
//

import AVFoundation
import Combine
import CoreAudioKit
import os.log

private let pluginLog = Logger(subsystem: "com.MichaelJancsy.ConjureDSP", category: "DSP")

public class ConjureDSPExtensionAudioUnit: AUAudioUnit, @unchecked Sendable
{
	// Rust DSP kernel (opaque pointer)
	private var kernel: DSPKernelRef!

	/// Expose kernel reference for audio capture (spectrogram visualization).
	/// Only used by AudioCaptureManager on the UI thread.
	var kernelReference: DSPKernelRef? { kernel }

	// MARK: - Shared Python Runtime

	/// App Group container URL for cross-app data sharing.
	private static let appGroupContainerURL: URL = AppGroupContainer.url

	/// Shared Python runtime provisioned by ConjureDSPTerminal into the App Group container.
	/// Used as PYTHONHOME — contains stdlib, numpy, scipy, and user-installed packages.
	static let pythonRuntimeURL: URL = appGroupContainerURL.appendingPathComponent("PythonRuntime")

	// MARK: - Parameter Tree (up to 16 parameters, with optional rich metadata)

	static let paramCount = 16

	/// Rich metadata for a parameter, declared by scripts via `PARAMS` dict.
	public struct ParamMetadata: Codable {
		public let name: String
		public let key: String?
		public let min: Float
		public let max: Float
		public let `default`: Float
		public let unit: String
		/// Mapping curve: "linear" (default) or "log" (exponential/logarithmic).
		public let curve: String?
		/// Display style: "slider" (default), "toggle", "choice", or "integer".
		public let style: String?
		/// Option labels for "choice" style parameters.
		public let options: [String]?

		var isToggle: Bool { style == "toggle" }
		var isChoice: Bool { style == "choice" }
		var isInteger: Bool { style == "integer" }

		/// Denormalize a 0–1 value to the actual parameter range.
		/// Integer-styled params snap the result to the nearest whole number
		/// within `[min, max]` so DAW automation reports exact integers.
		func denormalize(_ normalized: Float) -> Float {
			let n = Swift.min(Swift.max(normalized, 0), 1)
			let raw: Float
			if curve == "log", min > 0, max > 0 {
				raw = min * powf(max / min, n)
			} else {
				raw = min + n * (max - min)
			}
			if isInteger {
				let lo = Swift.min(min, max)
				let hi = Swift.max(min, max)
				return Swift.min(Swift.max(raw.rounded(), lo), hi)
			}
			return raw
		}

		/// Normalize an actual value to 0–1.
		/// Integer-styled params round the input first so round-trips through
		/// `denormalize`/`normalize` land exactly on integer steps.
		func normalize(_ actual: Float) -> Float {
			let actual = isInteger ? actual.rounded() : actual
			if curve == "log", min > 0, max > 0 {
				let ratio = Swift.max(actual / min, Float.ulpOfOne)
				let range = logf(max / min)
				guard range.magnitude > Float.ulpOfOne else { return 0 }
				return Swift.min(Swift.max(logf(ratio) / range, 0), 1)
			}
			let range = max - min
			guard range.magnitude > Float.ulpOfOne else { return 0 }
			return Swift.min(Swift.max((actual - min) / range, 0), 1)
		}
	}

	/// Current rich parameter metadata (nil = legacy 0–1 mode).
	private(set) var currentParamMetadata: [ParamMetadata]? = nil

	/// Fires after every script load with the new param metadata (or nil).
	public let paramMetadataDidChange = PassthroughSubject<[ParamMetadata]?, Never>()

	/// Fires each time render resources are allocated (on load and on DAW buffer/sample-rate changes).
	/// Carries the new maximum frame count and sample rate so the UI can update its budget display.
	public let renderConfigurationChanged = PassthroughSubject<(maxFrames: UInt32, sampleRate: Double), Never>()

	/// Script-declared algorithmic latency in samples (0 = no latency).
	/// Updated after each script load from the Rust kernel FFI.
	private(set) var _latencySamples: UInt32 = 0

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

		// Implementor callbacks reference currentParamMetadata dynamically so that
		// parameter normalization/denormalization stays correct across preset changes
		// without rebuilding the tree. Most DAW hosts (Ableton, GarageBand, Cubasis)
		// cache the parameter tree at instantiation and don't handle rebuilds well.
		tree.implementorValueObserver = { [unowned self] param, value in
			let idx = Int(param.address)
			if let meta = self.currentParamMetadata, idx < meta.count {
				let normalized = meta[idx].normalize(value)
				dsp_kernel_set_parameter(kernelRef, param.address, normalized)
			} else {
				dsp_kernel_set_parameter(kernelRef, param.address, value)
			}
		}
		tree.implementorValueProvider = { [unowned self] param in
			let normalized = dsp_kernel_get_parameter(kernelRef, param.address)
			let idx = Int(param.address)
			if let meta = self.currentParamMetadata, idx < meta.count {
				return meta[idx].denormalize(normalized)
			}
			return normalized
		}
		tree.implementorStringFromValueCallback = { [unowned self] param, valuePtr in
			let value = valuePtr?.pointee ?? param.value
			let idx = Int(param.address)
			if let meta = self.currentParamMetadata, idx < meta.count {
				let m = meta[idx]
				if m.isToggle {
					return value >= 0.5 ? "On" : "Off"
				}
				if m.isChoice, let opts = m.options {
					let choiceIdx = Int(value.rounded())
					if choiceIdx >= 0, choiceIdx < opts.count {
						return opts[choiceIdx]
					}
				}
				return Self.formatParamValue(value, unit: m.unit, isInteger: m.isInteger)
			}
			return String(format: "%.3f", value)
		}

		self.parameterTree = tree
	}

	/// Rebuild the parameter tree with rich metadata (real names, ranges, units).
	/// Always creates all 16 parameters — metadata params get real names/ranges,
	/// the rest stay as generic placeholders. The implementor callbacks still
	/// reference currentParamMetadata dynamically (set before calling this),
	/// so normalization/denormalization is always correct regardless of whether
	/// the host picks up the tree rebuild.
	///
	/// Hosts that observe parameterTree KVO (Logic Pro, AUM) will see updated
	/// names and ranges. Hosts that don't (Ableton) keep showing the names from
	/// instantiation but still get correct values via the dynamic callbacks.
	private func rebuildParameterTree(metadata: [ParamMetadata]) {
		let count = min(metadata.count, Self.paramCount)
		var params: [AUParameter] = []

		for i in 0..<Self.paramCount {
			if i < count {
				let meta = metadata[i]
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
			} else {
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
		}

		let tree = AUParameterTree.createTree(withChildren: params)
		let kernelRef = self.kernel!

		// Dynamic callbacks — same as buildParameterTree, reference currentParamMetadata
		tree.implementorValueObserver = { [unowned self] param, value in
			let idx = Int(param.address)
			if let meta = self.currentParamMetadata, idx < meta.count {
				let normalized = meta[idx].normalize(value)
				dsp_kernel_set_parameter(kernelRef, param.address, normalized)
			} else {
				dsp_kernel_set_parameter(kernelRef, param.address, value)
			}
		}
		tree.implementorValueProvider = { [unowned self] param in
			let normalized = dsp_kernel_get_parameter(kernelRef, param.address)
			let idx = Int(param.address)
			if let meta = self.currentParamMetadata, idx < meta.count {
				return meta[idx].denormalize(normalized)
			}
			return normalized
		}
		tree.implementorStringFromValueCallback = { [unowned self] param, valuePtr in
			let value = valuePtr?.pointee ?? param.value
			let idx = Int(param.address)
			if let meta = self.currentParamMetadata, idx < meta.count {
				let m = meta[idx]
				if m.isToggle {
					return value >= 0.5 ? "On" : "Off"
				}
				if m.isChoice, let opts = m.options {
					let choiceIdx = Int(value.rounded())
					if choiceIdx >= 0, choiceIdx < opts.count {
						return opts[choiceIdx]
					}
				}
				return Self.formatParamValue(value, unit: m.unit, isInteger: m.isInteger)
			}
			return String(format: "%.3f", value)
		}

		willChangeValue(forKey: "parameterTree")
		self.parameterTree = tree
		didChangeValue(forKey: "parameterTree")

		// Set kernel defaults (normalized, respects curve type)
		for (i, meta) in metadata.prefix(count).enumerated() {
			let normalized = meta.normalize(meta.default)
			dsp_kernel_set_parameter(kernel, UInt64(i), normalized)
		}

		// Signal hosts to re-read all parameter values
		willChangeValue(forKey: "allParameterValues")
		didChangeValue(forKey: "allParameterValues")
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

	/// Cached compiled WASM bytes for the current Rust script (nil for Python scripts).
	public var wasmBytes: Data? {
		return currentWasmBytes
	}

	/// Payload for script change notifications.
	public struct ScriptSourceChange {
		public let source: String
		public var processTimeMs: Double?
		public var budgetMs: Double?

		public init(source: String, processTimeMs: Double? = nil, budgetMs: Double? = nil) {
			self.source = source
			self.processTimeMs = processTimeMs
			self.budgetMs = budgetMs
		}
	}

	/// Publishes script source when it changes externally (preset selection, fullState restore, AI compile).
	public let scriptSourceDidChange = PassthroughSubject<ScriptSourceChange, Never>()

	/// Script-declared parameter names, keyed by address (0–7).
	/// nil = no names declared (backward compatible, show all 8 with default labels).
	private(set) var currentParamNames: [Int: String]? = nil

	/// Fires after every script load with the new param names (or nil).
	public let paramNamesDidChange = PassthroughSubject<[Int: String]?, Never>()

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

	/// Default preset loaded on AU init (before any fullState restore).
	static let defaultPresetResource = "preset_stereowidth"

	private func loadPythonScript() {
		let bundle = Bundle(for: type(of: self))

		// Python home: shared runtime in App Group container, provisioned by ConjureDSPTerminal.
		let runtimeURL = Self.pythonRuntimeURL
		let stdlibPath = runtimeURL.appendingPathComponent("lib/python3.14t").path
		guard FileManager.default.fileExists(atPath: stdlibPath) else {
			pluginLog.error("Python runtime not available at \(runtimeURL.path, privacy: .public) — launch ConjureDSP app to provision it")
			return
		}
		let pythonHome = runtimeURL.path
		self.pythonHome = pythonHome

		guard let scriptPath = bundle.path(forResource: Self.defaultPresetResource, ofType: "py") else {
			pluginLog.error("\(Self.defaultPresetResource).py not found in bundle, using Rust fallback DSP")
			return
		}

		// Set tones directory so conjuredsp.nam can resolve tone3000:// paths
		dsp_kernel_set_tones_dir(kernel, Self.appGroupContainerURL.appendingPathComponent("tones").path)

		pluginLog.info("Loading Python script. pythonHome=\(pythonHome, privacy: .public) scriptPath=\(scriptPath, privacy: .public)")
		let success = dsp_kernel_load_script(kernel, pythonHome, scriptPath)
		if success {
			pluginLog.info("Python DSP script loaded successfully")
			SentryHelper.breadcrumb("Script loaded", category: "dsp", data: ["language": "python"])

			// Read source so the UI can display it
			if let source = try? String(contentsOfFile: scriptPath, encoding: .utf8) {
				currentScriptSource = source
				readParamNames()
				// Override param names from source text only if no rich metadata
				if currentParamMetadata == nil,
				   let names = Self.parsePythonParamNames(fromSource: source) {
					currentParamNames = names
					paramNamesDidChange.send(names)
				}
			} else {
				readParamNames()
			}

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
				SentryHelper.capture("Failed to load Python DSP script", level: .error, category: "dsp.python", extra: ["error": errMsg])
			} else {
				pluginLog.error("Failed to load Python DSP script (no error details), using Rust fallback DSP")
				SentryHelper.capture("Failed to load Python DSP script (no error details)", level: .error, category: "dsp.python")
			}
		}
	}

	/// Convert a SCREAMING_SNAKE_CASE name to a display label.
	/// Replaces underscores with spaces, preserving original capitalization.
	/// e.g. BIT_DEPTH → "BIT DEPTH", RATE → "RATE"
	private static func displayLabel(from name: String) -> String {
		name.replacingOccurrences(of: "_", with: " ")
	}

	/// Parse param names from source text for either Python or Rust.
	///
	/// Looks for a `# Parameters:` (Python) or `// Parameters:` (Rust) marker,
	/// then reads subsequent declarations:
	/// - Python: `NAME = N`
	/// - Rust: `const NAME: usize = N;`
	///
	/// Converts SCREAMING_SNAKE names to Title Case labels (e.g. BIT_DEPTH → "Bit Depth").
	/// Returns nil if no marker is found.
	static func parseParamNames(fromSource source: String) -> [Int: String]? {
		let lines = source.components(separatedBy: .newlines)

		// Find the "# Parameters:" or "// Parameters:" marker line
		guard let markerIndex = lines.firstIndex(where: { line in
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			return trimmed.range(of: #"^(#|//)\s*Parameters:"#, options: .regularExpression) != nil
		}) else {
			return nil
		}

		// Try both Python (NAME = N) and Rust (const NAME: usize = N;) patterns
		let pythonPattern = try! NSRegularExpression(pattern: #"^\s*(\w+)\s*=\s*(\d+)\s*$"#)
		let rustPattern = try! NSRegularExpression(pattern: #"^\s*const\s+(\w+)\s*:\s*usize\s*=\s*(\d+)\s*;"#)
		var names: [Int: String] = [:]

		for i in (markerIndex + 1)..<lines.count {
			let line = lines[i]
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			if trimmed.isEmpty { continue }

			let range = NSRange(line.startIndex..., in: line)
			let match = pythonPattern.firstMatch(in: line, range: range)
				?? rustPattern.firstMatch(in: line, range: range)

			guard let match,
				  let nameRange = Range(match.range(at: 1), in: line),
				  let addrRange = Range(match.range(at: 2), in: line),
				  let addr = Int(line[addrRange]),
				  addr >= 0, addr < paramCount else {
				break
			}

			names[addr] = displayLabel(from: String(line[nameRange]))
		}

		return names.isEmpty ? nil : names
	}

	/// Parse Rust param names from source text (convenience wrapper).
	static func parseRustParamNames(fromSource source: String) -> [Int: String]? {
		parseParamNames(fromSource: source)
	}

	/// Parse Python param names from source text (convenience wrapper).
	static func parsePythonParamNames(fromSource source: String) -> [Int: String]? {
		parseParamNames(fromSource: source)
	}

	/// Read script-declared parameter metadata and names from the Rust kernel via FFI.
	/// Called after every successful script/WASM load.
	/// When rich metadata is present, rebuilds the parameter tree with real ranges.
	private func readParamNames() {
		// Read algorithmic latency (always valid after load, 0 if not declared).
		// Trigger KVO so the DAW host re-reads the latency property for delay compensation.
		let newLatency = dsp_kernel_latency_samples(kernel)
		if newLatency != _latencySamples {
			willChangeValue(forKey: "latency")
			_latencySamples = newLatency
			didChangeValue(forKey: "latency")
		}

		// Try rich metadata first
		if let metaPtr = dsp_kernel_param_metadata_json(kernel) {
			let metaJson = String(cString: metaPtr)
			if let data = metaJson.data(using: .utf8),
			   let metadata = try? JSONDecoder().decode([ParamMetadata].self, from: data),
			   !metadata.isEmpty {
				currentParamMetadata = metadata
				paramMetadataDidChange.send(metadata)

				// Derive param names from metadata
				var names: [Int: String] = [:]
				for (i, meta) in metadata.enumerated() {
					names[i] = meta.name
				}
				currentParamNames = names
				paramNamesDidChange.send(names)

				// Rebuild tree with real names/ranges for hosts that observe KVO (Logic)
				rebuildParameterTree(metadata: metadata)
				return
			}
		}

		// No rich metadata — if previous script had rich metadata, rebuild
		// the generic tree so names/ranges reset for KVO-observant hosts.
		let hadRichMetadata = currentParamMetadata != nil
		currentParamMetadata = nil
		paramMetadataDidChange.send(nil)
		if hadRichMetadata {
			buildParameterTree()
			willChangeValue(forKey: "allParameterValues")
			didChangeValue(forKey: "allParameterValues")
		}

		guard let ptr = dsp_kernel_param_names_json(kernel) else {
			currentParamNames = nil
			paramNamesDidChange.send(nil)
			return
		}
		let json = String(cString: ptr)
		guard let data = json.data(using: .utf8),
			  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
			currentParamNames = nil
			paramNamesDidChange.send(nil)
			return
		}
		var names: [Int: String] = [:]
		for (key, value) in dict {
			if let addr = Int(key), addr >= 0, addr < Self.paramCount {
				names[addr] = value
			}
		}
		currentParamNames = names.isEmpty ? nil : names
		paramNamesDidChange.send(currentParamNames)
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
			readParamNames()

			// Override param names from source text only if no rich metadata
			if currentParamMetadata == nil,
			   let names = Self.parsePythonParamNames(fromSource: source) {
				currentParamNames = names
				paramNamesDidChange.send(names)
			}

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
			SentryHelper.capture("Failed to reload Python DSP script", level: .error, category: "dsp.python", extra: ["error": errorMsg])
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
			SentryHelper.breadcrumb("Script loaded", category: "dsp", data: ["language": "rust", "wasmSize": bytes.count])
			readParamNames()

			// Inject NAM model if the WASM module declares one
			if let namError = injectNamModelIfNeeded() {
				return (false, namError, nil, nil)
			}

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
			SentryHelper.capture("Failed to load WASM module", level: .error, category: "dsp.wasm", extra: ["error": errorMsg])
			return (false, errorMsg, nil, nil)
		}
	}

	/// Resolve and inject a NAM model after WASM load, if the module declares one via `nam!()`.
	/// Reads the path from the WASM binary, resolves `tone3000://` paths to the App Group
	/// tones directory, parses the .nam JSON, serializes to binary protocol, and injects.
	/// Returns an error string on failure, nil on success or if no NAM model is declared.
	private func injectNamModelIfNeeded() -> String? {
		guard let namPathPtr = dsp_kernel_nam_path(kernel) else { return nil }
		let namPath = String(cString: namPathPtr)
		pluginLog.info("WASM module declares NAM model: \(namPath, privacy: .public)")

		// Resolve the path to a filesystem URL
		let namFileURL: URL?
		if namPath.hasPrefix("tone3000://") {
			// tone3000://toneId/modelId → App Group tones/toneId/modelId.nam
			let parts = namPath.dropFirst("tone3000://".count).components(separatedBy: "/")
			guard parts.count == 2 else {
				let msg = "Invalid tone3000:// path format: \(namPath). Expected tone3000://toneId/modelId"
				pluginLog.error("\(msg, privacy: .public)")
				SentryHelper.capture("Invalid tone3000:// path format", level: .error, category: "dsp.nam", extra: ["path": namPath])
				return msg
			}
			let toneId = parts[0]
			let modelId = parts[1]
			namFileURL = Self.appGroupContainerURL
				.appendingPathComponent("tones")
				.appendingPathComponent(toneId)
				.appendingPathComponent("\(modelId).nam")
		} else if namPath.hasPrefix("~") {
			namFileURL = URL(fileURLWithPath: NSString(string: namPath).expandingTildeInPath)
		} else {
			namFileURL = URL(fileURLWithPath: namPath)
		}

		guard let fileURL = namFileURL,
			  let namData = try? Data(contentsOf: fileURL) else {
			let msg = Self.namNotDownloadedMessage
			pluginLog.error("\(msg, privacy: .public)")
			SentryHelper.capture("NAM tone file not found", level: .error, category: "dsp.nam", extra: ["path": namPath])
			return msg
		}

		// Parse .nam JSON and serialize to binary protocol
		guard let namJson = try? JSONSerialization.jsonObject(with: namData) as? [String: Any],
			  let architecture = namJson["architecture"] as? String,
			  let configObj = namJson["config"],
			  let weightsArray = namJson["weights"] as? [Double] else {
			let msg = "Failed to parse .nam file at \(namPath)"
			pluginLog.error("\(msg, privacy: .public)")
			SentryHelper.capture("Failed to parse .nam file", level: .error, category: "dsp.nam", extra: ["path": namPath])
			return msg
		}

		let arch: UInt32 = architecture == "LSTM" ? 1 : 0
		let sampleRate = Float((namJson["sample_rate"] as? Double) ?? (namJson["sample_rate"] as? Int).map(Double.init) ?? 48000.0)

		guard let configData = try? JSONSerialization.data(withJSONObject: configObj) else {
			let msg = "Failed to serialize NAM config for \(namPath)"
			pluginLog.error("\(msg, privacy: .public)")
			SentryHelper.capture("Failed to serialize NAM config", level: .error, category: "dsp.nam", extra: ["path": namPath])
			return msg
		}

		// Build binary protocol: [arch:u32][sr:f32][config_len:u32][config_bytes][weight_count:u32][weights:f32...]
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

		let injected = binary.withUnsafeBytes { rawBuffer -> Bool in
			guard let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
				return false
			}
			return dsp_kernel_inject_nam(kernel, ptr, UInt(binary.count))
		}

		if injected {
			pluginLog.info("Injected NAM model (\(binary.count) bytes, \(architecture))")
			return nil
		} else {
			let msg = "Failed to inject NAM model data for \(namPath)"
			pluginLog.error("\(msg, privacy: .public)")
			SentryHelper.capture("Failed to inject NAM model data", level: .error, category: "dsp.nam", extra: ["path": namPath, "architecture": architecture, "binarySize": binary.count])
			return msg
		}
	}

	/// Compile source code (detecting language) and load into the DSP kernel.
	/// For Python: direct load (sync). For Rust: compile to WASM, cache, then load.
	/// Marker substring emitted by conjuredsp.nam when a NAM tone file is missing.
	private static let namNotDownloadedMarker = "NAM model not found"

	public func compileAndRun(source: String) async -> (success: Bool, error: String?, warning: String?, processTimeMs: Double?, budgetMs: Double?) {
		let language = ScriptLanguage.detect(from: source)

		switch language {
		case .python:
			let result = reloadScript(source: source)
			currentScriptLanguage = .python
			currentWasmBytes = nil

			// When a Python script fails because a NAM tone hasn't been
			// downloaded yet, report it as a warning (passthrough) rather
			// than a hard error so the status bar shows an amber hint
			// instead of a red error. Load a passthrough script into the
			// kernel so the old preset doesn't keep running.
			if !result.success,
			   let err = result.error,
			   err.contains(Self.namNotDownloadedMarker) {
				loadPassthroughScript()
				return (true, nil, Self.namNotDownloadedMessage, nil, nil)
			}

			return (result.success, result.error, nil, result.processTimeMs, result.budgetMs)

		case .rust:
			// Parse param names from source (only used if no rich metadata)
			let sourceParamNames = Self.parseRustParamNames(fromSource: source)

			// Check cache first (incorporate installed crate versions into cache key)
			let depsHash = CrateInstallManager.readManifestHash()
			let cache = WasmCache()
			if let cachedWasm = cache.cachedWasm(for: source, depsHash: depsHash) {
				let result = loadWasm(bytes: cachedWasm)
				if result.success {
					currentScriptSource = source
					currentScriptLanguage = .rust
					currentWasmBytes = cachedWasm
					// Only override param names if no rich metadata was extracted
					if currentParamMetadata == nil, let names = sourceParamNames {
						currentParamNames = names
						paramNamesDidChange.send(names)
					}
				}
				return Self.wasmResultWithWarning(result)
			}

			// Compile
			let compiler = RustCompiler()
			do {
				let wasmBytes = try await compiler.compile(source: source)
				cache.cache(wasm: wasmBytes, for: source, depsHash: depsHash)
				let result = loadWasm(bytes: wasmBytes)
				if result.success {
					currentScriptSource = source
					currentScriptLanguage = .rust
					currentWasmBytes = wasmBytes
					// Only override param names if no rich metadata was extracted
					if currentParamMetadata == nil, let names = sourceParamNames {
						currentParamNames = names
						paramNamesDidChange.send(names)
					}
				}
				return Self.wasmResultWithWarning(result)
			} catch {
				return (false, error.localizedDescription, nil, nil, nil)
			}
		}
	}

	private static let namNotDownloadedMessage = "This preset uses a NAM tone that hasn't been downloaded yet. Open the Tones panel from the toolbar to search and download it."

	/// Replace the current kernel backend with a minimal passthrough script
	/// so the previously loaded preset doesn't keep running.
	private func loadPassthroughScript() {
		guard let pythonHome = self.pythonHome else { return }
		let passthrough = """
		def process(inputs, outputs, frame_count, sample_rate, params):
		    for ch in range(len(inputs)):
		        outputs[ch][:frame_count] = inputs[ch][:frame_count]
		"""
		let tempDir = FileManager.default.temporaryDirectory
		let tempFile = tempDir.appendingPathComponent("passthrough_\(UUID().uuidString).py")
		guard let _ = try? passthrough.write(to: tempFile, atomically: true, encoding: .utf8) else { return }
		defer { try? FileManager.default.removeItem(at: tempFile) }
		dsp_kernel_load_script(kernel, pythonHome, tempFile.path)
	}

	/// Convert a WASM load result to a compile result, promoting NAM-not-downloaded errors to warnings.
	private static func wasmResultWithWarning(
		_ result: (success: Bool, error: String?, processTimeMs: Double?, budgetMs: Double?)
	) -> (success: Bool, error: String?, warning: String?, processTimeMs: Double?, budgetMs: Double?) {
		if !result.success,
		   let err = result.error,
		   err == namNotDownloadedMessage {
			return (true, nil, namNotDownloadedMessage, nil, nil)
		}
		return (result.success, result.error, nil, result.processTimeMs, result.budgetMs)
	}

	// MARK: - Subscription

	/// Verify a subscription token's signature and expiry, set kernel state.
	/// Returns the SubscriptionStatus raw value (0=Active, 1=GracePeriod, 2=Expired, 3=Cancelled, 4=NoSubscription).
	func verifyToken(_ token: String) -> UInt8 {
		return dsp_kernel_verify_token(kernel, token)
	}

	/// Set the subscription status directly.
	func setSubscriptionStatus(_ status: UInt8) {
		dsp_kernel_set_subscription_status(kernel, status)
	}

	/// Get the current subscription status.
	func subscriptionStatus() -> UInt8 {
		return dsp_kernel_subscription_status(kernel)
	}

	/// Get the grace period deadline as Unix seconds.
	func graceDeadlineUnix() -> Int64 {
		return dsp_kernel_grace_deadline_unix(kernel)
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

	/// Set the licensed state directly (used by tests).
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

	/// Algorithmic latency reported to the DAW for delay compensation.
	/// Declared by scripts via `LATENCY = <samples>` (Python) or `latency!(<samples>)` (Rust).
	public override var latency: TimeInterval {
		let sr = _outputBusses[0].format.sampleRate
		guard sr > 0 else { return 0 }
		return TimeInterval(_latencySamples) / sr
	}

	public override var channelCapabilities: [NSNumber] {
		return [NSNumber(value: 1), NSNumber(value: 1),
				NSNumber(value: 2), NSNumber(value: 2)]
	}

	public override func supportedViewConfigurations(
		_ availableViewConfigurations: [AUAudioUnitViewConfiguration]
	) -> IndexSet {
		IndexSet(integersIn: 0..<availableViewConfigurations.count)
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
					scriptSourceDidChange.send(ScriptSourceChange(source: source))
				}

			case .rust:
				// Try to load cached WASM bytes directly (instant, no compilation)
				if let wasmBytes = state[Self.wasmBytesKey] as? Data {
					let result = loadWasm(bytes: wasmBytes)
					if result.success {
						currentScriptSource = source
						currentScriptLanguage = .rust
						currentWasmBytes = wasmBytes
						// Override param names from source text only if no rich metadata
						if currentParamMetadata == nil, let names = Self.parseRustParamNames(fromSource: source) {
							currentParamNames = names
							paramNamesDidChange.send(names)
						}
						scriptSourceDidChange.send(ScriptSourceChange(source: source))
					}
				} else {
					// No cached WASM — just show the source, user must click Run
					currentScriptSource = source
					currentScriptLanguage = .rust
					scriptSourceDidChange.send(ScriptSourceChange(source: source))
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
		scriptSourceDidChange.send(ScriptSourceChange(source: source))

		let result = await compileAndRun(source: source)

		if result.success {
			// Sync DAW-facing currentPreset with KVO so the host updates its UI
			if let factoryNumber = preset.factoryPresetNumber {
				let auPreset = AUAudioUnitPreset()
				auPreset.number = factoryNumber
				auPreset.name = preset.name
				setCurrentPresetWithKVO(auPreset)
			} else {
				setCurrentPresetWithKVO(nil)
			}
			pluginLog.info("Selected preset: \(preset.name, privacy: .public)")
		}

		return ScriptSaveResult(success: result.success, error: result.error, warning: result.warning, processTimeMs: result.processTimeMs, budgetMs: result.budgetMs)
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

	/// Update the DAW-facing currentPreset with proper KVO notification.
	/// Does NOT trigger script loading — use when the script is already loaded.
	private func setCurrentPresetWithKVO(_ preset: AUAudioUnitPreset?) {
		willChangeValue(forKey: "currentPreset")
		_currentPreset = preset
		didChangeValue(forKey: "currentPreset")
	}

	public override var currentPreset: AUAudioUnitPreset? {
		get { return _currentPreset }
		set {
			willChangeValue(forKey: "currentPreset")
			_currentPreset = newValue
			didChangeValue(forKey: "currentPreset")
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
					scriptSourceDidChange.send(ScriptSourceChange(source: source))
					pluginLog.info("Loaded factory preset: \(entry.name, privacy: .public)")
				}
			case .rust:
				// Show source immediately, then compile async
				currentScriptSource = source
				currentScriptLanguage = .rust
				scriptSourceDidChange.send(ScriptSourceChange(source: source))
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
		renderConfigurationChanged.send((maxFrames: _maxFrames, sampleRate: _outputBus.format.sampleRate))
		SentryHelper.breadcrumb("allocateRenderResources", category: "au.lifecycle", data: [
			"sampleRate": _outputBus.format.sampleRate,
			"maxFrames": _maxFrames,
			"channels": inputChannelCount,
		])
	}

	public override func deallocateRenderResources() {
		dsp_kernel_deinitialize(kernel)
		inputPCMBuffer = nil
		originalAudioBufferList = nil
		mutableAudioBufferList = nil
		super.deallocateRenderResources()
		SentryHelper.breadcrumb("deallocateRenderResources", category: "au.lifecycle")
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

			// Query host musical context and transport state for BPM sync.
			// Both blocks are documented as render-thread-safe by Apple.
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
				nextEvent = Self.performAllSimultaneousEvents(kernel: kernel, now: now, event: nextEvent!, metadata: au.currentParamMetadata)
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

		// Stack-allocate channel buffer pointer arrays (no heap allocation on audio thread)
		withUnsafeTemporaryAllocation(of: UnsafePointer<Float>?.self, capacity: count) { inputBuf in
			withUnsafeTemporaryAllocation(of: UnsafeMutablePointer<Float>?.self, capacity: count) { outputBuf in
				for ch in 0..<count {
					let baseIn = inABL[ch].mData!.assumingMemoryBound(to: Float.self)
					inputBuf[ch] = UnsafePointer(baseIn.advanced(by: Int(frameOffset)))

					let baseOut = outABL[ch].mData!.assumingMemoryBound(to: Float.self)
					outputBuf[ch] = baseOut.advanced(by: Int(frameOffset))
				}
				dsp_kernel_process(kernel, inputBuf.baseAddress!, outputBuf.baseAddress!, channelCount, frameCount)
			}
		}
	}

	/// Walk the event linked list, handling all events at the current timestamp.
	/// Parameter events are dispatched to the Rust kernel; MIDI events are skipped.
	private static func performAllSimultaneousEvents(
		kernel: DSPKernelRef,
		now: AUEventSampleTime,
		event: UnsafePointer<AURenderEvent>,
		metadata: [ParamMetadata]?
	) -> UnsafePointer<AURenderEvent>? {
		var current: UnsafePointer<AURenderEvent>? = event
		repeat {
			guard let evt = current else { break }

			// Handle parameter events from DAW automation
			if evt.pointee.head.eventType == .parameter || evt.pointee.head.eventType == .parameterRamp {
				let paramEvent = evt.pointee.parameter
				let idx = Int(paramEvent.parameterAddress)
				// When rich metadata is active, paramEvent.value is in actual range (e.g. -21.5 dB).
				// Normalize to 0–1 before passing to the kernel.
				let value: Float
				if let meta = metadata, idx < meta.count {
					value = meta[idx].normalize(paramEvent.value)
				} else {
					value = paramEvent.value
				}
				dsp_kernel_set_parameter(kernel, paramEvent.parameterAddress, value)
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
