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
                // Notify Monaco editor and UI of the new script source + benchmark
                if !result.isError, let source = input["source"] as? String {
                    var change = ScriptSourceChange(source: source, origin: .mcp)
                    change.processTimeMs = result.processTimeMs
                    change.budgetMs = result.budgetMs
                    self.scriptSourceDidChange.send(change)
                }
                completion(result.json, result.isError)
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
        case "list_tones":
            Task { @MainActor in
                let result = self.mcpListTones()
                completion(result.0, result.1)
            }
        case "get_bundle_info":
            Task { @MainActor in
                let result = self.mcpGetBundleInfo()
                completion(result.0, result.1)
            }
        case "read_bundle_file":
            Task { @MainActor in
                let result = self.mcpReadBundleFile(input: input)
                completion(result.0, result.1)
            }
        case "write_bundle_file":
            Task { @MainActor in
                let result = self.mcpWriteBundleFile(input: input)
                completion(result.0, result.1)
            }
        default:
            completion(jsonStr(["error": "Unknown tool: \(name)"]), true)
        }
    }

    // MARK: - Tool Implementations

    /// Result from MCP compile_and_run, carrying both the JSON response and benchmark data
    /// for the UI timing indicator.
    private struct MCPCompileResult {
        let json: String
        let isError: Bool
        var processTimeMs: Double?
        var budgetMs: Double?
    }

    @MainActor
    private func mcpCompileAndRun(input: [String: Any]) async -> MCPCompileResult {
        guard let source = input["source"] as? String else {
            return MCPCompileResult(json: jsonStr(["error": "Missing required parameter: source"]), isError: true)
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
            return MCPCompileResult(
                json: jsonStr(response), isError: false,
                processTimeMs: result.processTimeMs, budgetMs: result.budgetMs
            )
        } else {
            mcpLastError = result.error
            return MCPCompileResult(
                json: jsonStr(["success": false, "error": result.error ?? "Unknown error"]), isError: false
            )
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
            // Surface bundle-ness + custom-UI status so Claude Code can
            // pick the right preset to edit when the user asks for
            // "the one with the custom UI". loadBundle is cached for
            // factory presets so this doesn't re-parse the manifest
            // every time list_presets runs.
            let bundle = pm.loadBundle(for: preset)
            return [
                "name": preset.name,
                "is_factory": preset.isFactory,
                "is_bundle": preset.isBundle || preset.isFactory,
                "has_custom_ui": bundle?.hasCustomUI ?? false,
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
        let scaffoldUI = (input["scaffold_ui"] as? Bool) ?? false
        let pm = presetManager
        do {
            let preset = try pm.saveUserBundle(
                name: name, source: source,
                language: currentScriptLanguage,
                scaffoldUI: scaffoldUI
            )
            var response: [String: Any] = ["success": true, "name": preset.name]
            if scaffoldUI {
                response["scaffolded_ui"] = true
                response["note"] = "Starter ui/index.html written. Edit it via write_bundle_file to customize the custom HTML/JS UI."
            }
            return (jsonStr(response), false)
        } catch {
            return (jsonStr(["error": "Failed to save preset: \(error.localizedDescription)"]), true)
        }
    }

    // MARK: - Bundle tools

    /// Return everything Claude Code needs to reason about the current
    /// preset bundle: whether it's a bundle at all, whether it ships a
    /// custom UI, the manifest's UI block, and the list of editable
    /// text files inside. Binary assets (PNG/WOFF) don't appear in the
    /// file list because write_bundle_file takes UTF-8 only.
    @MainActor
    private func mcpGetBundleInfo() -> (String, Bool) {
        guard let preset = presetManager.currentPreset,
              let bundle = presetManager.loadBundle(for: preset) else {
            // Legacy single-file presets have no bundle view — surface
            // that explicitly rather than returning an error.
            return (jsonStr(["bundle": NSNull()]), false)
        }

        let entries = BundleFilePickerEntries.entries(for: bundle)
        let files: [[String: Any]] = entries.map { entry in
            var dict: [String: Any] = [
                "path": entry.relativePath,
                "kind": entry.kind.rawValue,
            ]
            dict["language_id"] = entry.monacoLanguageID
            return dict
        }

        var uiInfo: [String: Any] = [:]
        if let ui = bundle.manifest.ui {
            uiInfo["entryHTML"] = ui.entryHTML ?? "ui/index.html"
            if let w = ui.width { uiInfo["width"] = w }
            if let h = ui.height { uiInfo["height"] = h }
            if let fps = ui.fps { uiInfo["fps"] = fps }
            uiInfo["audioFrames"] = ui.audioFrames ?? false
        }

        var bundleInfo: [String: Any] = [
            "name": bundle.name,
            "root_path": bundle.rootURL.path,
            "language": bundle.language.rawValue,
            "has_custom_ui": bundle.hasCustomUI,
            "is_factory": preset.isFactory,
            "editable": !preset.isFactory, // factory bundles live in read-only Resources
            "files": files,
        ]
        if !uiInfo.isEmpty { bundleInfo["ui"] = uiInfo }

        return (jsonStr(["bundle": bundleInfo]), false)
    }

    /// Safely resolve a caller-supplied relative path against the current
    /// bundle's root. Rejects absolute paths, `..` escapes, and any path
    /// whose resolved location falls outside the bundle. Returns the
    /// resolved URL on success, or a user-facing error message on failure
    /// (the URL slot is nil then).
    @MainActor
    private func resolveBundleFilePath(
        _ input: [String: Any]
    ) -> (bundle: PresetBundle?, url: URL?, error: String?) {
        guard let preset = presetManager.currentPreset,
              let bundle = presetManager.loadBundle(for: preset) else {
            return (nil, nil, "No bundle loaded. Current preset is not a bundle.")
        }
        guard let raw = input["path"] as? String, !raw.isEmpty else {
            return (bundle, nil, "Missing required parameter: path")
        }
        if raw.hasPrefix("/") {
            return (bundle, nil, "path must be relative to the bundle root; absolute paths are not allowed.")
        }
        let candidate = bundle.rootURL.appendingPathComponent(raw).standardizedFileURL
        let rootStandardized = bundle.rootURL.standardizedFileURL
        guard candidate.path.hasPrefix(rootStandardized.path + "/") || candidate.path == rootStandardized.path else {
            return (bundle, nil, "path escapes the bundle root (got '\(raw)').")
        }
        return (bundle, candidate, nil)
    }

    @MainActor
    private func mcpReadBundleFile(input: [String: Any]) -> (String, Bool) {
        let resolved = resolveBundleFilePath(input)
        if let error = resolved.error {
            return (jsonStr(["error": error]), true)
        }
        guard let url = resolved.url else {
            return (jsonStr(["error": "Could not resolve bundle file URL."]), true)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return (jsonStr(["error": "File not found: \(input["path"] ?? "")"]), true)
        }
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return (jsonStr(["error": "File is not UTF-8 text. Binary bundle assets (images, fonts) aren't readable through this tool."]), true)
        }
        return (jsonStr(["path": input["path"] ?? "", "content": content]), false)
    }

    @MainActor
    private func mcpWriteBundleFile(input: [String: Any]) -> (String, Bool) {
        let resolved = resolveBundleFilePath(input)
        if let error = resolved.error {
            return (jsonStr(["error": error]), true)
        }
        guard let url = resolved.url else {
            return (jsonStr(["error": "Could not resolve bundle file URL."]), true)
        }
        guard let content = input["content"] as? String else {
            return (jsonStr(["error": "Missing required parameter: content"]), true)
        }
        guard let preset = presetManager.currentPreset else {
            return (jsonStr(["error": "No current preset."]), true)
        }
        if preset.isFactory {
            return (jsonStr(["error": "Factory presets are read-only. Save the preset with save_preset first to create an editable user bundle."]), true)
        }
        do {
            // Parent dirs may not exist yet — e.g. first write to
            // ui/assets/style.css in a bundle that only had ui/.
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return (jsonStr(["error": "Write failed: \(error.localizedDescription)"]), true)
        }
        // Manifest edits can flip hasCustomUI on or off; refresh so the
        // in-plugin UI toggle state tracks the new state.
        if url.lastPathComponent == PresetManifest.filename {
            presetManager.refreshPresets()
        }
        return (jsonStr([
            "success": true,
            "path": input["path"] ?? "",
            "bytes_written": content.utf8.count,
        ]), false)
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

        let validTopics = ["params", "filters", "delays", "oscillators", "utilities", "accel", "nam", "all"]
        guard validTopics.contains(topic) else {
            return (jsonStr(["error": "Invalid topic: \(topic). Valid topics: \(validTopics.joined(separator: ", "))"]), true)
        }

        var sections: [String] = []
        if topic == "params" || topic == "all" { sections.append(DSPDocumentation.params) }
        if topic == "filters" || topic == "all" { sections.append(DSPDocumentation.filters) }
        if topic == "delays" || topic == "all" { sections.append(DSPDocumentation.delays) }
        if topic == "oscillators" || topic == "all" { sections.append(DSPDocumentation.oscillators) }
        if topic == "utilities" || topic == "all" { sections.append(DSPDocumentation.utilities) }
        if topic == "accel" || topic == "all" { sections.append(DSPDocumentation.accel) }
        if topic == "nam" || topic == "all" { sections.append(DSPDocumentation.nam) }

        return (jsonStr(["topic": topic, "docs": sections.joined(separator: "\n\n")]), false)
    }

    // MARK: - Package listing

    private func mcpListPackages() -> (String, Bool) {
        let sitePackages = AppGroupContainer.url
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

    // MARK: - Tone listing

    @MainActor
    private func mcpListTones() -> (String, Bool) {
        let store = ToneModelStore()
        let tones = store.downloadedModels.map { model -> [String: Any] in
            var entry: [String: Any] = [
                "tone_name": model.toneName,
                "author": model.author,
                "gear": model.gear,
                "model_name": model.modelName,
                "model_size": model.modelSize,
                "path": model.tone3000Path,
            ]
            if !model.tags.isEmpty { entry["tags"] = model.tags }
            if !model.makes.isEmpty { entry["makes"] = model.makes }
            return entry
        }
        if tones.isEmpty {
            return (jsonStr([
                "tones": [] as [Any],
                "note": "No tones downloaded. Use the Tones browser (toolbar button) to search and download tones from tone3000.com.",
            ]), false)
        }
        return (jsonStr(["tones": tones, "count": tones.count]), false)
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

        // Count downloaded NAM tones by scanning the App Group tones directory
        let tonesURL = AppGroupContainer.url.appendingPathComponent("tones")
        if let toneDirs = try? FileManager.default.contentsOfDirectory(at: tonesURL, includingPropertiesForKeys: [.isDirectoryKey]) {
            let namCount = toneDirs.filter { dir in
                (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }.count
            if namCount > 0 {
                parts.append("\(namCount) NAM tone(s) downloaded (use list_tones tool).")
            }
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
