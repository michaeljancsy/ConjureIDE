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

/// See CustomUIWebView.swift for the same `ParamFlow` category. Stage 5
/// (implementorValueObserver = what actually gets written to the kernel)
/// and stage 6 (main-thread poll of what the audio thread reads) both
/// log here.
private let paramFlow = Logger(
    subsystem: "com.MichaelJancsy.ConjureDSP.ConjureDSPExtension",
    category: "ParamFlow"
)

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
	public struct ParamMetadata: Codable, Equatable {
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

		/// Field-by-field equality. Used by the MCP `compile_and_run`
		/// handler to decide whether the kernel's freshly-extracted
		/// metadata differs from what the AU already has, and so a
		/// param-tree rebuild is needed.
		public static func == (lhs: ParamMetadata, rhs: ParamMetadata) -> Bool {
			return lhs.name == rhs.name
				&& lhs.key == rhs.key
				&& lhs.min == rhs.min
				&& lhs.max == rhs.max
				&& lhs.default == rhs.default
				&& lhs.unit == rhs.unit
				&& lhs.curve == rhs.curve
				&& lhs.style == rhs.style
				&& lhs.options == rhs.options
		}

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

	/// Compare manifest-declared metadata against what the DSP kernel
	/// extracted from the source. Logs (os_log) on any name / range /
	/// unit / curve / style / options drift. The manifest wins at
	/// runtime either way — the DSP still processes whatever it reads —
	/// but the author should see the mismatch loudly so they can fix it.
	static func validateManifestVsDSP(manifest: [ParamMetadata], dsp: [ParamMetadata]) {
		if manifest.count != dsp.count {
			pluginLog.warning("Manifest declares \(manifest.count, privacy: .public) params, DSP declares \(dsp.count, privacy: .public) — counts disagree")
		}
		let pairs = zip(manifest, dsp)
		for (i, (m, d)) in pairs.enumerated() {
			if m.name != d.name {
				pluginLog.warning("param[\(i, privacy: .public)] name drift: manifest=\(m.name, privacy: .public) dsp=\(d.name, privacy: .public)")
			}
			if m.min != d.min || m.max != d.max {
				pluginLog.warning("param[\(i, privacy: .public)] \(m.name, privacy: .public) range drift: manifest=\(m.min, privacy: .public)..\(m.max, privacy: .public) dsp=\(d.min, privacy: .public)..\(d.max, privacy: .public)")
			}
			if m.unit != d.unit {
				pluginLog.warning("param[\(i, privacy: .public)] \(m.name, privacy: .public) unit drift: manifest=\(m.unit, privacy: .public) dsp=\(d.unit, privacy: .public)")
			}
			if (m.curve ?? "linear") != (d.curve ?? "linear") {
				pluginLog.warning("param[\(i, privacy: .public)] \(m.name, privacy: .public) curve drift: manifest=\(m.curve ?? "linear", privacy: .public) dsp=\(d.curve ?? "linear", privacy: .public)")
			}
			if (m.style ?? "slider") != (d.style ?? "slider") {
				pluginLog.warning("param[\(i, privacy: .public)] \(m.name, privacy: .public) style drift: manifest=\(m.style ?? "slider", privacy: .public) dsp=\(d.style ?? "slider", privacy: .public)")
			}
		}
	}

	/// Current rich parameter metadata (nil = legacy 0–1 mode).
	private(set) var currentParamMetadata: [ParamMetadata]? = nil

	/// Set by `applyManifestParams` when a preset ships declarations in
	/// `manifest.json`. Makes `currentParamMetadata` authoritative over
	/// whatever the kernel later extracts from the DSP source, and gates
	/// the post-load validator.
	private var manifestDeclaredMetadata: [ParamMetadata]? = nil

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
				// paramFlow.notice("[5.swift.implObserver] idx=\(idx, privacy: .public) raw=\(value, privacy: .public) normalized=\(normalized, privacy: .public)")
				dsp_kernel_set_parameter(kernelRef, param.address, normalized)
			} else {
				// paramFlow.notice("[5.swift.implObserver.nometa] idx=\(idx, privacy: .public) v=\(value, privacy: .public)")
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

	/// Apply parameter metadata declared in `manifest.json` as the
	/// authoritative source. Intended to be called BEFORE
	/// `compileAndRun` / `reloadScript` / `loadWasm` when selecting a
	/// preset, so the AU parameter tree, stock sliders, and the custom-UI
	/// bridge's `_init` payload all reflect the new preset's params the
	/// instant the webview loads — rather than waiting on rustc to
	/// finish and the kernel to extract metadata.
	///
	/// Pass nil to return to "DSP-extracted metadata is truth" mode for
	/// presets whose manifest has no `params` key (v1 bundles).
	public func applyManifestParams(_ metadata: [ParamMetadata]?) {
		manifestDeclaredMetadata = metadata
		if let metadata, !metadata.isEmpty {
			// Visible marker so `log stream --subsystem ...` in Console
			// can confirm the running binary has the schema-v2 manifest-
			// first path active. If this line doesn't appear on preset
			// switch, the plugin host is still running a pre-fix build.
			let names = metadata.map { $0.name }.joined(separator: ",")
			pluginLog.info("[manifest-v2] applyManifestParams count=\(metadata.count, privacy: .public) names=\(names, privacy: .public)")
			currentParamMetadata = metadata
			var nameMap: [Int: String] = [:]
			for (i, meta) in metadata.enumerated() { nameMap[i] = meta.name }
			currentParamNames = nameMap
			// CRITICAL: rebuild the tree BEFORE broadcasting
			// paramMetadataDidChange. The subscription in
			// AudioUnitViewController calls `ps.attach(to: tree)` inside
			// the sink, which snapshots the CURRENT values. If we send
			// first, that attach hits the PREVIOUS preset's tree — so
			// `ParameterState.values` gets populated with stale data and
			// the UI shows wrong numbers (e.g. "1 Hz 0 Q" instead of
			// "1000 Hz 1 Q") for the whole duration of the Rust compile.
			rebuildParameterTree(metadata: metadata)
			paramNamesDidChange.send(nameMap)
			paramMetadataDidChange.send(metadata)
		} else {
			pluginLog.info("[manifest-v2] applyManifestParams(nil) — falling back to DSP-extracted metadata")
			// Manifest has no declarations. Don't yank metadata here —
			// let the next compile repopulate it from DSP extraction as
			// before. Clearing preemptively would cause a flash of
			// "no params" between preset select and compile complete.
		}
	}

	/// Clear all parameter metadata and rebuild the legacy generic 16-slot
	/// parameter tree.
	///
	/// Use this when the previous preset's tree must NOT be inherited —
	/// notably when creating a brand-new preset whose template hasn't
	/// compiled yet. Unlike `applyManifestParams(nil)`, this actively yanks
	/// stale state instead of preserving it. The "preserve" semantics of
	/// `applyManifestParams(nil)` exist so a slow Rust compile during a
	/// preset switch doesn't flash "no params"; for a freshly-created
	/// preset there's no prior-tree-worth-keeping, so the flash is correct.
	@MainActor
	public func resetParameterTreeToGeneric() {
		manifestDeclaredMetadata = nil
		currentParamMetadata = nil
		currentParamNames = [:]
		// Rebuild tree BEFORE broadcasting (same critical ordering as
		// applyManifestParams) so subscribers that re-attach inside the
		// sink don't snapshot the stale tree.
		buildParameterTree()
		paramNamesDidChange.send(nil)
		paramMetadataDidChange.send(nil)
	}

	/// Force a parameter-tree rebuild from the kernel's currently-extracted
	/// metadata, bypassing the manifest-priority guard in `readParamNames`.
	///
	/// Called by the MCP `compile_and_run` handler so scratchpad iteration
	/// on a script with a different params! / PARAMS shape isn't masked by
	/// the active bundle's manifest declarations. The normal preset-load
	/// path keeps manifest-priority semantics — that's what makes the UI
	/// render with correct defaults during a slow Rust compile. But MCP
	/// `compile_and_run` is an explicit "test this new code" intent: the
	/// caller wants the tree to reflect what the new code actually
	/// declares, not what the bundle's stale manifest still says.
	///
	/// Returns true if the tree was rebuilt (kernel metadata differed
	/// from current), false if the kernel's metadata matches what the AU
	/// already has (so no work was needed).
	@MainActor
	public func rebuildParamTreeFromKernelIfChanged() -> Bool {
		// Read kernel-extracted metadata (or nil if the script declares none)
		let kernelMeta: [ParamMetadata]? = {
			guard let metaPtr = dsp_kernel_param_metadata_json(kernel) else { return nil }
			let json = String(cString: metaPtr)
			guard let data = json.data(using: .utf8),
			      let decoded = try? JSONDecoder().decode([ParamMetadata].self, from: data),
			      !decoded.isEmpty
			else { return nil }
			return decoded
		}()

		// Compare to current — if identical, nothing to do
		if kernelMeta == currentParamMetadata { return false }

		// Different. Clear manifest priority and rebuild from kernel.
		if let meta = kernelMeta {
			manifestDeclaredMetadata = nil
			currentParamMetadata = meta
			var nameMap: [Int: String] = [:]
			for (i, m) in meta.enumerated() { nameMap[i] = m.name }
			currentParamNames = nameMap
			// Same critical ordering as readParamNames: rebuild tree
			// BEFORE broadcasting paramMetadataDidChange.
			rebuildParameterTree(metadata: meta)
			paramNamesDidChange.send(nameMap)
			paramMetadataDidChange.send(meta)
		} else {
			// New script declares no metadata — back to legacy generic tree.
			resetParameterTreeToGeneric()
		}
		return true
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
				// paramFlow.notice("[5.swift.implObserver] idx=\(idx, privacy: .public) raw=\(value, privacy: .public) normalized=\(normalized, privacy: .public)")
				dsp_kernel_set_parameter(kernelRef, param.address, normalized)
			} else {
				// paramFlow.notice("[5.swift.implObserver.nometa] idx=\(idx, privacy: .public) v=\(value, privacy: .public)")
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

	/// Lazily resolved path to Python runtime. Re-checks the filesystem if nil,
	/// so it picks up a runtime provisioned after AU initialization.
	private var pythonHome: String? {
		if let cached = _pythonHome { return cached }
		let stdlibPath = Self.pythonRuntimeURL.appendingPathComponent("lib/python3.14t").path
		guard FileManager.default.fileExists(atPath: stdlibPath) else { return nil }
		_pythonHome = Self.pythonRuntimeURL.path
		return _pythonHome
	}
	private var _pythonHome: String?

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
		public enum Origin {
			case mcp
			case other
		}
		public let source: String
		public let origin: Origin
		public var processTimeMs: Double?
		public var budgetMs: Double?

		public init(source: String, origin: Origin = .other, processTimeMs: Double? = nil, budgetMs: Double? = nil) {
			self.source = source
			self.origin = origin
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

	/// Debug-only timer that samples `dsp_kernel_get_parameter` from the
	/// main thread and logs the result. Stage 6 of the parameter-flow
	/// trace: shows what value the audio render thread actually reads.
	/// If UI writes show up in stages 3–5 but stage 6 stays stale, the
	/// problem is between implementorValueObserver and the kernel.
	private var kernelPollTimer: Timer?

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

		startKernelPollTimer()
	}

	/// Last kernel-poll values (per address) so the 100ms tick only
	/// emits a log line when a parameter actually changed. Keeps the
	/// ParamFlow log readable instead of 10 identical lines/second.
	private var lastKernelPollValues: [AUParameterAddress: Float] = [:]

	/// Fires at 100ms, logs `[6.kernel.poll]` ONLY for params whose
	/// kernel value changed since the last tick. A silent tick means
	/// the audio thread still sees the same values as last time.
	private func startKernelPollTimer() {
		let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
			guard let self else { return }
			let kernelRef = self.kernel!
			let activeCount: Int = {
				if let meta = self.currentParamMetadata { return meta.count }
				return Self.paramCount
			}()
			for i in 0..<activeCount {
				let addr = AUParameterAddress(i)
				let v = dsp_kernel_get_parameter(kernelRef, addr)
				if self.lastKernelPollValues[addr] != v {
					// paramFlow.notice("[6.kernel.poll] idx=\(i, privacy: .public) v=\(v, privacy: .public)")
					self.lastKernelPollValues[addr] = v
				}
			}
		}
		RunLoop.main.add(t, forMode: .common)
		kernelPollTimer = t
	}

	/// Default preset loaded on AU init (before any fullState restore).
	static let defaultPresetResource = "preset_stereowidth"

	private func loadPythonScript() {
		let bundle = Bundle(for: type(of: self))

		// Python home: shared runtime in App Group container, provisioned by ConjureDSPTerminal.
		// Uses the lazy pythonHome property which re-checks the filesystem if not yet cached.
		guard let pythonHome = self.pythonHome else {
			pluginLog.error("Python runtime not available at \(Self.pythonRuntimeURL.path, privacy: .public) — launch ConjureDSP app to provision it")
			return
		}

		// Factory presets are `.cdp` bundle directories under Resources/presets/
		// since the bundle conversion. Resolve the entry script via PresetBundle
		// so the path lines up with whatever manifest.entry says (typically
		// `process.py` but not guaranteed).
		guard let presetBundleURL = bundle.url(
			forResource: Self.defaultPresetResource,
			withExtension: PresetBundle.bundleExtension,
			subdirectory: "presets"
		), let presetBundle = PresetBundle.load(from: presetBundleURL) else {
			pluginLog.error("\(Self.defaultPresetResource).\(PresetBundle.bundleExtension) not found or malformed under Resources/presets, using Rust fallback DSP")
			return
		}
		let scriptPath = presetBundle.entryScriptURL.path

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

	/// Attempt to load the default preset. Used by the UI to retry after the
	/// Python runtime is provisioned on first launch. Returns true if the
	/// script loaded successfully (and fires scriptSourceDidChange).
	func retryLoadDefaultPreset() -> Bool {
		guard currentScriptSource == nil else { return true }
		loadPythonScript()
		if let source = currentScriptSource {
			scriptSourceDidChange.send(ScriptSourceChange(source: source))
			return true
		}
		return false
	}

	/// Convert a SCREAMING_SNAKE_CASE name to a display label.
	/// Replaces underscores with spaces, preserving original capitalization.
	/// e.g. BIT_DEPTH → "BIT DEPTH", RATE → "RATE"
	private static func displayLabel(from name: String) -> String {
		name.replacingOccurrences(of: "_", with: " ")
	}

	// Static regex constants — compiled once at first use. fatalError on bad pattern
	// is intentional: a broken regex is a programmer error caught at dev time, not a
	// user-facing crash.
	private static let pythonParamNameRegex: NSRegularExpression = {
		guard let re = try? NSRegularExpression(pattern: #"^\s*(\w+)\s*=\s*(\d+)\s*$"#) else {
			fatalError("ConjureDSPExtensionAudioUnit: pythonParamNameRegex pattern is invalid")
		}
		return re
	}()

	private static let rustParamNameRegex: NSRegularExpression = {
		guard let re = try? NSRegularExpression(pattern: #"^\s*const\s+(\w+)\s*:\s*usize\s*=\s*(\d+)\s*;"#) else {
			fatalError("ConjureDSPExtensionAudioUnit: rustParamNameRegex pattern is invalid")
		}
		return re
	}()

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
		let pythonPattern = ConjureDSPExtensionAudioUnit.pythonParamNameRegex
		let rustPattern = ConjureDSPExtensionAudioUnit.rustParamNameRegex
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

		// If the preset's `manifest.json` declared `params`, those are
		// already in place (via `applyManifestParams` before load) and
		// take priority over whatever the kernel extracted. Run the
		// drift validator and skip the override. Authors can edit the
		// manifest freely; the DSP keeps processing whatever it reads.
		if let manifest = manifestDeclaredMetadata, !manifest.isEmpty {
			if let metaPtr = dsp_kernel_param_metadata_json(kernel) {
				let json = String(cString: metaPtr)
				if let data = json.data(using: .utf8),
				   let dspMeta = try? JSONDecoder().decode([ParamMetadata].self, from: data),
				   !dspMeta.isEmpty {
					Self.validateManifestVsDSP(manifest: manifest, dsp: dspMeta)
				}
			}
			return
		}

		// Try rich metadata first
		if let metaPtr = dsp_kernel_param_metadata_json(kernel) {
			let metaJson = String(cString: metaPtr)
			if let data = metaJson.data(using: .utf8),
			   let metadata = try? JSONDecoder().decode([ParamMetadata].self, from: data),
			   !metadata.isEmpty {
				currentParamMetadata = metadata

				// Derive param names from metadata
				var names: [Int: String] = [:]
				for (i, meta) in metadata.enumerated() {
					names[i] = meta.name
				}
				currentParamNames = names

				// CRITICAL ORDERING (mirrors applyManifestParams):
				// rebuild the tree BEFORE broadcasting
				// paramMetadataDidChange. ParameterState's sink in
				// AudioUnitViewController calls `ps.attach(to:
				// au.parameterTree)` synchronously inside the sink
				// and snapshots the CURRENT values from whatever
				// tree it sees. If we sent first, attach would hit
				// the PREVIOUS (pre-rebuild) tree and populate
				// `ParameterState.values` with stale data — and
				// the custom-UI WebView's `sendInit`, which reads
				// from state.values, would ship those stale values
				// to JS. Authors see (e.g.) mix=0% in the slider
				// while the kernel actually runs at the manifest's
				// 0.5 default. Nudging any slider eventually
				// converges (set() updates _values) but the first
				// load shows wrong numbers.
				rebuildParameterTree(metadata: metadata)
				paramNamesDidChange.send(names)
				paramMetadataDidChange.send(metadata)
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

	/// Strip leading/trailing markdown code fences (e.g. ```python ... ```) that
	/// LLMs sometimes wrap around code. Only fences on their own lines at the
	/// very start and end of the source are removed.
	static func stripCodeFences(_ source: String) -> String {
		var lines = source.components(separatedBy: "\n")

		// Trim leading blank lines, remember how many so trailing trim is symmetric.
		while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
			lines.removeFirst()
		}
		while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
			lines.removeLast()
		}

		guard let first = lines.first, let last = lines.last, lines.count >= 2 else {
			return source
		}
		let firstTrim = first.trimmingCharacters(in: .whitespaces)
		let lastTrim = last.trimmingCharacters(in: .whitespaces)
		guard firstTrim.hasPrefix("```"), lastTrim == "```" else {
			return source
		}
		lines.removeFirst()
		lines.removeLast()
		return lines.joined(separator: "\n")
	}

	public func compileAndRun(source rawSource: String) async -> (success: Bool, error: String?, warning: String?, processTimeMs: Double?, budgetMs: Double?) {
		let source = Self.stripCodeFences(rawSource)
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
		def process(inputs, outputs, frame_count, sample_rate, params, _transport, _telemetry):
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
		// `Timer.invalidate()` must be called on the same thread the timer
		// was scheduled on (RunLoop.main, see `startKernelPollTimer`). This
		// class is `@unchecked Sendable`, so `deinit` can run on a
		// background thread — e.g. headless AU instances during `auval`,
		// or DAW track unloads dispatched off-main. Capture the timer
		// locally so the dispatched closure doesn't reach back into a
		// half-destroyed `self`.
		let timer = kernelPollTimer
		if let timer {
			if Thread.isMainThread {
				timer.invalidate()
			} else {
				DispatchQueue.main.async { timer.invalidate() }
			}
		}
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

		// CRITICAL ORDERING: apply manifest params BEFORE
		// `pm.setCurrentPreset`. setCurrentPreset triggers the SwiftUI
		// view update that recreates `CustomUIWebView` with a new `.id`
		// — the new webview starts loading immediately and races to
		// post 'ready'. If `ParameterState.paramMetadata` isn't already
		// the NEW preset's by the time 'ready' arrives, `sendInit`
		// would send stale metadata from the previous preset, and the
		// custom UI would render against wrong param indices for the
		// whole duration of the compile.
		if let bundle = pm.loadBundle(for: preset) {
			pluginLog.info("[manifest-v2] selectPreset '\(preset.name, privacy: .public)' loaded bundle, manifest.schemaVersion=\(bundle.manifest.schemaVersion, privacy: .public), params=\(bundle.manifest.params?.count ?? 0, privacy: .public)")
			applyManifestParams(bundle.manifest.resolvedParamMetadata())
		} else {
			pluginLog.info("[manifest-v2] selectPreset '\(preset.name, privacy: .public)' — no bundle")
			applyManifestParams(nil)
		}

		// Now kick off the view update — webview gets the right
		// metadata from its first `sendInit`.
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

	/// Clear the DAW-facing currentPreset with KVO notification. Used
	/// from non-file-scope callers (e.g. the MCP save_preset handler
	/// in a separate extension file) when a fork moves us off of a
	/// factory preset — no more factory number to advertise.
	func clearDAWCurrentPreset() {
		setCurrentPresetWithKVO(nil)
	}

	public override var currentPreset: AUAudioUnitPreset? {
		get { return _currentPreset }
		set {
			willChangeValue(forKey: "currentPreset")
			_currentPreset = newValue
			didChangeValue(forKey: "currentPreset")
			guard let preset = newValue, preset.number >= 0 else { return }

			guard let entry = FactoryPresetRegistry.entries.first(where: { $0.number == preset.number }) else { return }

			// Factory presets ship as `.cdp` bundles under the extension's
			// Resources. Resolve the bundle dir, then read the entry script
			// named in `manifest.entry` (mirrors the user/repo bundle path).
			let bundle = Bundle(for: type(of: self))
			guard let bundleURL = bundle.url(
				forResource: entry.resourceName,
				withExtension: PresetBundle.bundleExtension,
				subdirectory: "presets"
			),
				  let presetBundle = PresetBundle.load(from: bundleURL),
				  let source = try? presetBundle.readSource() else {
				pluginLog.error("Factory bundle script not found: \(entry.resourceName, privacy: .public)")
				return
			}

			// Apply manifest params BEFORE load — lets the custom UI
			// render immediately without waiting for rustc / kernel.
			applyManifestParams(presetBundle.manifest.resolvedParamMetadata())

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
				// DAW-originated render-thread automation event. Not logged —
				// can't os_log from the audio thread without risking xruns.
				// Stage 6's main-thread kernel poll will show the resulting
				// kernel value; that's the observable side-effect.
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
