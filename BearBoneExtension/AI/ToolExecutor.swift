import AVFoundation
import Foundation
import os

/// Executes tool calls by dispatching to BearBone AU functions.
/// All tool calls run on the main actor since they interact with AU state.
@MainActor
final class ToolExecutor {
    private let log = Logger(subsystem: "com.MichaelJancsy.BearBone", category: "ToolExecutor")

    /// Weak reference to the audio unit — tools need access to compile/run, parameters, etc.
    weak var audioUnit: BearBoneExtensionAudioUnit?

    /// Reference to the preset manager for preset operations.
    var presetManager: PresetManager?

    /// Callback to update the editor script source when compile_and_run succeeds.
    /// Parameters: (source, processTimeMs, budgetMs)
    var onScriptChanged: ((String, Double?, Double?) -> Void)?

    /// The last error from a script load/compile (tracked separately from AU).
    private(set) var lastError: String?

    init() {}

    /// Execute a tool call and return the result as a JSON string.
    func execute(name: String, input: [String: Any]) async -> (content: String, isError: Bool) {
        log.info("Executing tool: \(name)")

        switch name {
        case "compile_and_run":
            return await executeCompileAndRun(input: input)
        case "get_script":
            return executeGetScript()
        case "get_error":
            return executeGetError()
        case "set_parameter":
            return executeSetParameter(input: input)
        case "get_parameters":
            return executeGetParameters()
        case "get_audio_state":
            return executeGetAudioState()
        case "list_presets":
            return executeListPresets()
        case "save_preset":
            return executeSavePreset(input: input)
        case "toggle_bypass":
            return executeToggleBypass()
        default:
            return (jsonString(["error": "Unknown tool: \(name)"]), true)
        }
    }

    // MARK: - Tool Implementations

    private func executeCompileAndRun(input: [String: Any]) async -> (content: String, isError: Bool) {
        guard let source = input["source"] as? String else {
            return (jsonString(["error": "Missing required parameter: source"]), true)
        }
        guard let au = audioUnit else {
            return (jsonString(["error": "Audio unit not available"]), true)
        }

        let result = await au.compileAndRun(source: source)
        Analytics.track(.aiGenerate, properties: [
            "language": ScriptLanguage.detect(from: source).rawValue,
            "success": result.success,
        ])
        Analytics.flush()

        if result.success {
            lastError = nil
            onScriptChanged?(source, result.processTimeMs, result.budgetMs)
            var response: [String: Any] = ["success": true]
            if let processTimeMs = result.processTimeMs, let budgetMs = result.budgetMs {
                response["process_time_ms"] = String(format: "%.2f", processTimeMs)
                response["budget_ms"] = String(format: "%.2f", budgetMs)
                let percent = (processTimeMs / budgetMs) * 100
                response["budget_percent"] = String(format: "%.1f%%", percent)
            }
            return (jsonString(response), false)
        } else {
            lastError = result.error
            return (jsonString(["success": false, "error": result.error ?? "Unknown error"]), false)
        }
    }

    private func executeGetScript() -> (content: String, isError: Bool) {
        guard let au = audioUnit else {
            return (jsonString(["error": "Audio unit not available"]), true)
        }
        if let source = au.scriptSource {
            return (jsonString(["source": source, "language": au.currentScriptLanguage.rawValue]), false)
        } else {
            return (jsonString(["source": nil as String?, "language": "python"]), false)
        }
    }

    private func executeGetError() -> (content: String, isError: Bool) {
        if let error = lastError {
            return (jsonString(["error": error]), false)
        } else {
            return (jsonString(["error": nil as String?]), false)
        }
    }

    private func executeSetParameter(input: [String: Any]) -> (content: String, isError: Bool) {
        guard let au = audioUnit else {
            return (jsonString(["error": "Audio unit not available"]), true)
        }
        guard let index = (input["index"] as? Int) ?? (input["index"] as? Double).map({ Int($0) }) else {
            return (jsonString(["error": "Missing required parameter: index"]), true)
        }
        guard let value = (input["value"] as? Double) ?? (input["value"] as? Int).map({ Double($0) }) else {
            return (jsonString(["error": "Missing required parameter: value"]), true)
        }
        guard (0..<16).contains(index) else {
            return (jsonString(["error": "Parameter index must be 0-15, got \(index)"]), true)
        }

        // Set via the parameter tree so DAW automation stays in sync.
        // Pass the actual value — the AU parameter tree clamps to min/max
        // and the implementorValueObserver normalizes for the kernel.
        if let param = au.parameterTree?.parameter(withAddress: AUParameterAddress(index)) {
            param.value = Float(value)
            return (jsonString(["success": true, "index": index, "value": Double(param.value)]), false)
        }

        return (jsonString(["error": "Parameter \(index) not found"]), true)
    }

    private func executeGetParameters() -> (content: String, isError: Bool) {
        guard let au = audioUnit else {
            return (jsonString(["error": "Audio unit not available"]), true)
        }
        let metadata = au.currentParamMetadata
        var params: [[String: Any]] = []
        for i in 0..<16 {
            if let param = au.parameterTree?.parameter(withAddress: AUParameterAddress(i)) {
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
        return (jsonString(["parameters": params]), false)
    }

    private func executeGetAudioState() -> (content: String, isError: Bool) {
        guard let au = audioUnit else {
            return (jsonString(["error": "Audio unit not available"]), true)
        }
        let outputBus = au.outputBusses[0]
        let response: [String: Any] = [
            "sample_rate": outputBus.format.sampleRate,
            "channel_count": Int(outputBus.format.channelCount),
            "max_frames": Int(au.maximumFramesToRender),
            "bypassed": au.shouldBypassEffect,
        ]
        return (jsonString(response), false)
    }

    private func executeListPresets() -> (content: String, isError: Bool) {
        guard let pm = presetManager else {
            return (jsonString(["error": "Preset manager not available"]), true)
        }
        let presetList = pm.presets.map { preset -> [String: Any] in
            [
                "name": preset.name,
                "is_factory": preset.isFactory,
                "language": preset.language.rawValue,
            ]
        }
        return (jsonString(["presets": presetList]), false)
    }

    private func executeSavePreset(input: [String: Any]) -> (content: String, isError: Bool) {
        guard let name = input["name"] as? String else {
            return (jsonString(["error": "Missing required parameter: name"]), true)
        }
        guard let au = audioUnit, let source = au.scriptSource else {
            return (jsonString(["error": "No script loaded to save"]), true)
        }
        guard let pm = presetManager else {
            return (jsonString(["error": "Preset manager not available"]), true)
        }

        do {
            let preset = try pm.saveUserPreset(name: name, source: source, language: au.currentScriptLanguage)
            return (jsonString(["success": true, "name": preset.name]), false)
        } catch {
            return (jsonString(["error": "Failed to save preset: \(error.localizedDescription)"]), true)
        }
    }

    private func executeToggleBypass() -> (content: String, isError: Bool) {
        guard let au = audioUnit else {
            return (jsonString(["error": "Audio unit not available"]), true)
        }
        au.shouldBypassEffect.toggle()
        return (jsonString(["bypassed": au.shouldBypassEffect]), false)
    }

    // MARK: - Helpers

    private func jsonString(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }
}
