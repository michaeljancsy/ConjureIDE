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
