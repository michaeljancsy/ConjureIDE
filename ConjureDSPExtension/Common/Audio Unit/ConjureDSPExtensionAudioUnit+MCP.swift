//
//  ConjureDSPExtensionAudioUnit+MCP.swift
//  ConjureDSPExtension
//
//  MCPToolProvider conformance — allows the host app's MCP server to execute tools
//  on the AU by casting `auAudioUnit as? MCPToolProvider`.
//

import AVFoundation
import Combine
import ObjectiveC
import os.log

private let mcpLog = Logger(subsystem: "com.MichaelJancsy.ConjureDSP", category: "MCP")

extension ConjureDSPExtensionAudioUnit: MCPToolProvider {

    /// Execute an MCP tool by name with JSON input.
    /// Bridges from the @objc completion-handler API to the AU's async Swift methods.
    @objc func executeMCPTool(_ name: String, inputJSON: String, completion: @escaping (String, Bool) -> Void) {
        mcpLog.info("MCP tool call: \(name, privacy: .public)")

        let input: [String: Any]
        if let data = inputJSON.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            input = parsed
        } else {
            input = [:]
        }

        // Dispatch async tools via Task, sync tools directly
        switch name {
        case "compile_and_run":
            Task { @MainActor in
                let result = await self.mcpCompileAndRun(input: input)
                // Notify Monaco editor of the new script source
                if !result.1, let source = input["source"] as? String {
                    self.scriptSourceDidChange.send(ScriptSourceChange(source: source))
                }
                completion(result.0, result.1)
            }
        case "get_script":
            let result = mcpGetScript()
            completion(result.0, result.1)
        case "get_error":
            let result = mcpGetError()
            completion(result.0, result.1)
        case "set_parameter":
            Task { @MainActor in
                let result = self.mcpSetParameter(input: input)
                completion(result.0, result.1)
            }
        case "get_parameters":
            Task { @MainActor in
                let result = self.mcpGetParameters()
                completion(result.0, result.1)
            }
        case "get_audio_state":
            Task { @MainActor in
                let result = self.mcpGetAudioState()
                completion(result.0, result.1)
            }
        case "list_presets":
            Task { @MainActor in
                let result = self.mcpListPresetsImpl()
                completion(result.0, result.1)
            }
        case "save_preset":
            Task { @MainActor in
                let result = self.mcpSavePresetImpl(input: input)
                completion(result.0, result.1)
            }
        case "toggle_bypass":
            Task { @MainActor in
                let result = self.mcpToggleBypass()
                completion(result.0, result.1)
            }
        case "get_docs":
            let result = mcpGetDocs(input: input)
            completion(result.0, result.1)
        case "list_packages":
            let result = mcpListPackages()
            completion(result.0, result.1)
        default:
            completion(jsonStr(["error": "Unknown tool: \(name)"]), true)
        }
    }

    // MARK: - Tool Implementations

    @MainActor
    private func mcpCompileAndRun(input: [String: Any]) async -> (String, Bool) {
        guard let source = input["source"] as? String else {
            return (jsonStr(["error": "Missing required parameter: source"]), true)
        }
        let result = await compileAndRun(source: source)
        if result.success {
            mcpLastError = nil
            var response: [String: Any] = ["success": true]
            if let processTimeMs = result.processTimeMs, let budgetMs = result.budgetMs {
                response["process_time_ms"] = String(format: "%.2f", processTimeMs)
                response["budget_ms"] = String(format: "%.2f", budgetMs)
                let percent = (processTimeMs / budgetMs) * 100
                response["budget_percent"] = String(format: "%.1f%%", percent)
            }
            if _latencySamples > 0 {
                response["latency_samples"] = Int(_latencySamples)
            }
            return (jsonStr(response), false)
        } else {
            mcpLastError = result.error
            return (jsonStr(["success": false, "error": result.error ?? "Unknown error"]), false)
        }
    }

    private func mcpGetScript() -> (String, Bool) {
        if let source = scriptSource {
            return (jsonStr(["source": source, "language": currentScriptLanguage.rawValue]), false)
        } else {
            return (jsonStr(["source": NSNull(), "language": "python"]), false)
        }
    }

    private func mcpGetError() -> (String, Bool) {
        if let error = mcpLastError {
            return (jsonStr(["error": error]), false)
        } else {
            return (jsonStr(["error": NSNull()]), false)
        }
    }

    @MainActor
    private func mcpSetParameter(input: [String: Any]) -> (String, Bool) {
        guard let index = (input["index"] as? Int) ?? (input["index"] as? Double).map({ Int($0) }) else {
            return (jsonStr(["error": "Missing required parameter: index"]), true)
        }
        guard let value = (input["value"] as? Double) ?? (input["value"] as? Int).map({ Double($0) }) else {
            return (jsonStr(["error": "Missing required parameter: value"]), true)
        }
        guard (0..<16).contains(index) else {
            return (jsonStr(["error": "Parameter index must be 0-15, got \(index)"]), true)
        }
        if let param = parameterTree?.parameter(withAddress: AUParameterAddress(index)) {
            param.value = Float(value)
            return (jsonStr(["success": true, "index": index, "value": Double(param.value)]), false)
        }
        return (jsonStr(["error": "Parameter \(index) not found"]), true)
    }

    @MainActor
    private func mcpGetParameters() -> (String, Bool) {
        let metadata = currentParamMetadata
        var params: [[String: Any]] = []
        for i in 0..<Self.paramCount {
            if let param = parameterTree?.parameter(withAddress: AUParameterAddress(i)) {
                var entry: [String: Any] = [
                    "index": i,
                    "name": param.displayName,
                    "value": Double(param.value),
                    "min": Double(param.minValue),
                    "max": Double(param.maxValue),
                ]
                if let meta = metadata, i < meta.count {
                    entry["unit"] = meta[i].unit
                }
                params.append(entry)
            }
        }
        return (jsonStr(["parameters": params]), false)
    }

    @MainActor
    private func mcpGetAudioState() -> (String, Bool) {
        let outputBus = outputBusses[0]
        let sr = outputBus.format.sampleRate
        var response: [String: Any] = [
            "sample_rate": sr,
            "channel_count": Int(outputBus.format.channelCount),
            "max_frames": Int(maximumFramesToRender),
            "bypassed": shouldBypassEffect,
            "latency_samples": Int(_latencySamples),
        ]
        if _latencySamples > 0 {
            response["latency_seconds"] = Double(_latencySamples) / sr
        }

        // Memory monitoring fields
        let residentBytes = dsp_kernel_process_resident_bytes()
        let residentMB = Double(residentBytes) / 1_048_576.0
        response["resident_memory_mb"] = round(residentMB * 10) / 10

        if let k = kernelReference {
            let baselineBytes = dsp_kernel_memory_baseline_bytes(k)
            let baselineMB = Double(baselineBytes) / 1_048_576.0
            response["memory_growth_mb"] = round((residentMB - baselineMB) * 10) / 10

            let wasmBytes = dsp_kernel_wasm_memory_bytes(k)
            if wasmBytes > 0 {
                response["wasm_memory_mb"] = round(Double(wasmBytes) / 1_048_576.0 * 10) / 10
            }
        }
        return (jsonStr(response), false)
    }

    @MainActor
    private func mcpListPresetsImpl() -> (String, Bool) {
        let pm = presetManager
        let presetList = pm.presets.map { preset -> [String: Any] in
            [
                "name": preset.name,
                "is_factory": preset.isFactory,
                "language": preset.language.rawValue,
            ]
        }
        return (jsonStr(["presets": presetList]), false)
    }

    @MainActor
    private func mcpSavePresetImpl(input: [String: Any]) -> (String, Bool) {
        guard let name = input["name"] as? String else {
            return (jsonStr(["error": "Missing required parameter: name"]), true)
        }
        guard let source = scriptSource else {
            return (jsonStr(["error": "No script loaded to save"]), true)
        }
        let pm = presetManager
        do {
            let preset = try pm.saveUserPreset(name: name, source: source, language: currentScriptLanguage)
            return (jsonStr(["success": true, "name": preset.name]), false)
        } catch {
            return (jsonStr(["error": "Failed to save preset: \(error.localizedDescription)"]), true)
        }
    }

    @MainActor
    private func mcpToggleBypass() -> (String, Bool) {
        shouldBypassEffect.toggle()
        return (jsonStr(["bypassed": shouldBypassEffect]), false)
    }

    // MARK: - Documentation

    private func mcpGetDocs(input: [String: Any]) -> (String, Bool) {
        guard let topic = input["topic"] as? String else {
            return (jsonStr(["error": "Missing required parameter: topic"]), true)
        }

        let validTopics = ["params", "filters", "delays", "oscillators", "utilities", "all"]
        guard validTopics.contains(topic) else {
            return (jsonStr(["error": "Invalid topic: \(topic). Valid topics: \(validTopics.joined(separator: ", "))"]), true)
        }

        var sections: [String] = []
        if topic == "params" || topic == "all" { sections.append(Self.docsParams) }
        if topic == "filters" || topic == "all" { sections.append(Self.docsFilters) }
        if topic == "delays" || topic == "all" { sections.append(Self.docsDelays) }
        if topic == "oscillators" || topic == "all" { sections.append(Self.docsOscillators) }
        if topic == "utilities" || topic == "all" { sections.append(Self.docsUtilities) }

        return (jsonStr(["topic": topic, "docs": sections.joined(separator: "\n\n")]), false)
    }

    // MARK: - Package listing

    private func mcpListPackages() -> (String, Bool) {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.MichaelJancsy.ConjureDSP"
        ) else {
            return (jsonStr(["error": "App Group container not available"]), true)
        }

        let sitePackages = containerURL
            .appendingPathComponent("PythonRuntime/lib/python3.14t/site-packages")
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: sitePackages, includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return (jsonStr(["packages": [] as [Any], "note": "No site-packages directory found"]), false)
        }

        var packages: [[String: Any]] = []
        for item in contents {
            let name = item.lastPathComponent
            if name.hasSuffix(".dist-info") {
                let stem = String(name.dropLast(".dist-info".count))
                if let dashRange = stem.range(of: "-", options: .backwards) {
                    let pkgName = String(stem[..<dashRange.lowerBound])
                        .replacingOccurrences(of: "_", with: "-")
                    let normalized = pkgName.lowercased().replacingOccurrences(of: "-", with: "_")
                    let version = String(stem[dashRange.upperBound...])
                    let isBundled = PackageInstallManager.bundledPackagePrefixes.contains(normalized)
                    packages.append([
                        "name": pkgName,
                        "version": version,
                        "built_in": isBundled,
                    ])
                }
            }
        }

        packages.sort { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }

        // Rust crates
        var crates: [[String: Any]] = [
            ["name": "conjuredsp", "version": "built-in", "built_in": true],
        ]
        if let manifest = CrateInstallManager.readManifest() {
            for (name, entry) in manifest.crates where entry.userRequested {
                crates.append([
                    "name": name,
                    "version": entry.version,
                    "built_in": false,
                ])
            }
        }
        crates.sort { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }

        return (jsonStr(["python_packages": packages, "rust_crates": crates]), false)
    }

    // Static documentation strings — comprehensive API reference derived from actual source.

    private static let docsParams = """
    # Parameter Builders

    Available builders and their default ranges:

    freq — 20-20000 Hz, log curve, default 1000
    db — -60 to +12 dB, linear curve, default 0
    time_ms — 0.1-1000 ms, log curve, default 100
    mix — 0.0-1.0, linear, default 0.5
    pct — 0-100%, linear, default 50
    toggle — 0/1, rendered as switch in UI, default 0
    ratio — 1-20 :1, linear, default 4
    param — generic with explicit min/max, default=min, linear, no unit

    ## Python syntax

    Builders are functions that return dicts. Customize via keyword arguments:

      from conjuredsp import freq, db, time_ms, mix, pct, toggle, choice, ratio, param

      PARAMS = {
          "cutoff": freq(),                                # use defaults: 20-20000 Hz
          "attack": time_ms(0.5, 50, default=5),           # positional min/max, keyword default
          "damping": freq(min=500, max=16000, default=4000),  # all keyword args
          "drive": pct(default=70),
          "mix": mix(default=0.35),
          "bypass": toggle(),
          "mode": choice("Low", "Mid", "High", default="Mid"),  # Python-only dropdown
      }

    param() accepts: param(min, max, unit="", default=None, curve="linear")

    choice(*labels, default=None) — Python-only. Dropdown menu, receives selected index as float \
    (0.0, 1.0, ...). Requires at least 2 labels.

    ## Rust syntax

    Builders are const functions. Customize via method chaining:

      params! {
          CUTOFF = freq(),                                  // use defaults: 20-20000 Hz
          ATTACK = time_ms().min(0.5).max(50.0).default(5.0),
          DAMPING = freq().min(500.0).max(16000.0).default(4000.0),
          DRIVE = pct().default(70.0),
          MIX = mix().default(0.35),
          BYPASS = toggle(),
      }

    Chaining methods: .min(val), .max(val), .default(val), .unit("str"), .curve("log" or "linear")
    All are const fn and can be used in static/const contexts.

    ## How parameters are delivered to scripts

    With PARAMS metadata: scripts receive denormalized actual values (e.g., 1000.0 Hz).
    Without PARAMS: scripts receive raw 0-1 normalized floats (legacy mode).
    Python params arg is a dict keyed by name. Rust params are accessed via ctx.param(INDEX).
    """

    private static let docsFilters = """
    # Filters — BiquadCoeffs + Biquad

    Biquad filters using Audio EQ Cookbook formulas (Robert Bristow-Johnson).
    All internal math uses f64 for precision. Create one Biquad per channel.

    ## BiquadCoeffs — coefficient calculation (stateless)

    3-argument filters (freq, q, sample_rate):
      .lowpass(freq, q, sr)    — passes frequencies below cutoff
      .highpass(freq, q, sr)   — passes frequencies above cutoff
      .bandpass(freq, q, sr)   — passes a frequency band (constant skirt gain)
      .notch(freq, q, sr)      — removes a frequency band
      .allpass(freq, q, sr)    — passes all frequencies, shifts phase

    4-argument filters (freq, q, gain_db, sample_rate):
      .peak(freq, q, gain_db, sr)      — boosts or cuts at center frequency
      .lowshelf(freq, q, gain_db, sr)   — boosts or cuts below cutoff
      .highshelf(freq, q, gain_db, sr)  — boosts or cuts above cutoff

    Parameters:
      freq — center/cutoff frequency in Hz
      q — quality factor (0.707 = Butterworth/no resonance, higher = narrower/more resonant)
      gain_db — boost/cut in dB (only for peak, lowshelf, highshelf)
      sr — sample rate in Hz

    Python: BiquadCoeffs.lowpass(freq, q, sr) — returns BiquadCoeffs instance
    Rust: BiquadCoeffs::lowpass(freq, q, sr) — returns BiquadCoeffs (Copy type)

    ## Biquad — stateful filter (Direct Form II Transposed)

    Python: Biquad(coeffs=None) — passthrough if no coeffs
    Rust: Biquad::new() — const fn, passthrough by default. Copy type.

    Methods:
      .set_coeffs(coeffs)        — update coefficients without resetting state
      .process_sample(x) -> y    — filter one sample (f64 in Rust, float in Python)
      .reset()                   — zero internal state (z1, z2)

    ## Typical usage pattern

    Python:
      _filters = None
      def process(inputs, outputs, frame_count, sample_rate, params):
          global _filters
          if _filters is None:
              _filters = [Biquad() for _ in range(len(inputs))]
          coeffs = BiquadCoeffs.lowpass(params["cutoff"], 0.707, sample_rate)
          for ch in range(len(inputs)):
              _filters[ch].set_coeffs(coeffs)
              for i in range(frame_count):
                  outputs[ch][i] = _filters[ch].process_sample(inputs[ch][i])

    Rust:
      static mut FILTERS: [Biquad; 2] = [Biquad::new(); 2];
      // in process():
      let coeffs = BiquadCoeffs::lowpass(ctx.param(CUTOFF) as f64, 0.707, ctx.sample_rate() as f64);
      unsafe {
          FILTERS[c].set_coeffs(coeffs);
          ctx.set_output(c, i, FILTERS[c].process_sample(ctx.input(c, i) as f64) as f32);
      }
    """

    private static let docsDelays = """
    # DelayLine — Circular Buffer

    Pre-allocated circular buffer for delay effects with fractional-sample interpolation.

    ## Construction

    Python: DelayLine(max_samples: int) — numpy float32 backed
      Sizing: int(max_delay_seconds * sample_rate)
      Property: .max_samples → int

    Rust: DelayLine::<SIZE>::new() — const generic, compile-time size
      SIZE must be a const. Example: DelayLine::<48000>::new()
      Stored in static mut for persistence: static mut DELAYS: [DelayLine<48000>; 2] = [DelayLine::new(); 2];

    ## Methods

    .write(sample)              — write one sample and advance write head
    .read(delay_samples)        — fractional delay with linear interpolation (f64 delay arg in Rust)
    .read_cubic(delay_samples)  — fractional delay with 4-point Hermite interpolation (better for
                                  pitch shifting and modulated delays)
    .tap(delay_samples)         — integer delay, no interpolation (int arg in Python, usize in Rust)
    .clear()                    — zero buffer and reset write position

    ## Delay time conversion

    delay_samples = delay_time_ms * 0.001 * sample_rate
    max_samples = int(max_delay_seconds * sample_rate)

    ## Notes

    - write() before read() each sample — write advances the head, read looks backward
    - read(0) and tap(0) return the sample at the current write position (just written)
    - read(1) / tap(1) returns the previous sample
    - Rust DelayLine uses f32 samples, f64 delay argument for read/read_cubic
    """

    private static let docsOscillators = """
    # Oscillators — LFO + Waveform Functions

    ## LFO — Stateful Low-Frequency Oscillator

    Python: LFO(sample_rate, freq=1.0, waveform="sine")
    Rust: Lfo::new() → defaults to 1 Hz sine at 44100 Hz. Call .init(sr, freq) each callback.

    Methods:
      .tick() -> float          — advance one sample, returns value in [-1, 1]
      .set_freq(hz)             — update frequency
      .set_waveform(wf)         — Python: string ("sine","triangle","saw","square")
                                  Rust: Waveform enum (Waveform::Sine, Triangle, Saw, Square)
      .reset()                  — reset phase to 0
      .value                    — last tick() value (attribute/field, not a method call)

    Python-only:
      .tick_n(n) -> np.ndarray  — advance n samples, returns float32 array of shape (n,)
                                  More efficient than calling tick() in a loop.

    Rust-only:
      .init(sample_rate, freq)  — set sample rate and frequency. Call at start of each process()
                                  callback to handle sample rate changes.

    ## Waveform enum (Rust)

    Waveform::Sine, Waveform::Triangle, Waveform::Saw, Waveform::Square

    ## Stateless waveform functions

    All take phase in [0, 1) and return value in [-1, 1]:
      sine(phase)      — sin(2*pi*phase)
      triangle(phase)  — triangle wave
      saw(phase)       — sawtooth wave (rising)

    advance_phase(phase, freq, sample_rate) -> new_phase  — advance phase by one sample, wraps at 1.0

    ## Multi-channel LFO pattern

    Only call tick() once per sample (not once per channel). Use .value for subsequent channels:
      Python: mod = lfo.tick() if ch == 0 else lfo.value
      Rust: let mod_val = if c == 0 { LFO.tick() } else { LFO.value };
    """

    private static let docsUtilities = """
    # Utility Functions

    Stateless helpers for unit conversion and common audio math. All use f64 in Rust, float in Python.

    ## Unit conversion

    db_to_gain(db) -> gain          — 0 dB = 1.0, -6 dB ≈ 0.5, -20 dB = 0.1
    gain_to_db(gain) -> db          — inverse of db_to_gain, clamps to avoid log(0)
    ms_to_samples(ms, sr) -> int    — milliseconds to sample count (rounded)
    samples_to_ms(samples, sr)      — sample count to milliseconds
    freq_to_period(freq, sr)        — frequency in Hz to period in samples

    ## Smoothing

    smooth_coeff(time_ms, sr) -> alpha
      One-pole smoothing coefficient. Use as: state = alpha * state + (1 - alpha) * target
      Larger time_ms = slower smoothing (alpha closer to 1.0).
      time_ms=0 or negative returns 0.0 (instant).

    ## Waveshaping

    soft_clip(x, drive=1.0)   — tanh saturation. drive > 1 increases distortion.
    lerp(a, b, t)             — linear interpolation. t=0 → a, t=1 → b.

    ## Crossfade

    Rust: crossfade(dry: f32, wet: f32, mix: f32) -> f32
      Per-sample linear crossfade. mix=0 → dry, mix=1 → wet.

    Python: crossfade(dry, wet, mix, out, n)
      Buffer-level linear crossfade. Writes to out[:n] in-place.
      dry, wet, out are numpy arrays. mix is a float.

    Python-only: equal_power_crossfade(dry, wet, mix, out, n)
      Constant-energy crossfade using sine/cosine curves.
      Preserves perceived loudness at 50% mix (no energy dip).
    """

    // MARK: - State Summary

    /// Synchronous summary of current AU state for MCP initialize instructions.
    @objc func mcpStateSummary() -> String {
        var parts: [String] = []

        // Audio state
        let sr = outputBusses[0].format.sampleRate
        let ch = Int(outputBusses[0].format.channelCount)
        let bypass = shouldBypassEffect ? ", bypassed" : ""
        parts.append("Audio: \(Int(sr)) Hz, \(ch)ch\(bypass).")

        // Script info
        if let source = scriptSource {
            let lang = currentScriptLanguage.rawValue
            // Try to extract a meaningful identifier (first non-import, non-comment line)
            let lines = source.components(separatedBy: .newlines)
            let hasParams = lines.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("PARAMS") }
            parts.append("Script loaded (\(lang)\(hasParams ? ", has PARAMS" : "")).")
        } else {
            parts.append("No script loaded.")
        }

        // Active parameters
        let metadata = currentParamMetadata
        var paramDescs: [String] = []
        for i in 0..<Self.paramCount {
            if let param = parameterTree?.parameter(withAddress: AUParameterAddress(i)),
               param.displayName != "Parameter \(i + 1)" {
                let unit = (metadata != nil && i < metadata!.count) ? metadata![i].unit : ""
                let unitStr = unit.isEmpty ? "" : " \(unit)"
                paramDescs.append("\(param.displayName)=\(formatValue(param.value))\(unitStr)")
            }
        }
        if !paramDescs.isEmpty {
            parts.append("Params: \(paramDescs.joined(separator: ", ")).")
        }

        if _latencySamples > 0 {
            parts.append("Latency: \(_latencySamples) samples.")
        }

        return parts.joined(separator: " ")
    }

    /// Format a parameter value concisely (no trailing zeros).
    private func formatValue(_ value: Float) -> String {
        if value == Float(Int(value)) {
            return "\(Int(value))"
        }
        return String(format: "%.1f", value)
    }

    // MARK: - Helpers

    /// Last error tracked for MCP tool calls (per-instance via associated object).
    private static var mcpLastErrorKey: UInt8 = 0
    private var mcpLastError: String? {
        get { objc_getAssociatedObject(self, &Self.mcpLastErrorKey) as? String }
        set { objc_setAssociatedObject(self, &Self.mcpLastErrorKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    private func jsonStr(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }
}
