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
                let result = self.mcpGetParameters(input: input)
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
                let result = await self.mcpSavePresetImpl(input: input)
                completion(result.0, result.1)
            }
        case "duplicate_bundle":
            Task { @MainActor in
                let result = await self.mcpDuplicateBundleImpl(input: input)
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
        case "validate_bundle":
            Task { @MainActor in
                let result = self.mcpValidateBundle()
                completion(result.0, result.1)
            }
        case "smoke_test_ui":
            Task { @MainActor in
                let result = await self.mcpSmokeTestUI()
                completion(result.0, result.1)
            }
        case "dsp_probe":
            Task { @MainActor in
                let result = await self.mcpDspProbe(input: input)
                completion(result.0, result.1)
            }
        case "set_state":
            Task { @MainActor in
                let result = self.mcpSetState(input: input)
                completion(result.0, result.1)
            }
        case "get_state":
            Task { @MainActor in
                let result = self.mcpGetState(input: input)
                completion(result.0, result.1)
            }
        case "reset_state":
            Task { @MainActor in
                let result = self.mcpResetState(input: input)
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
        // Mute output across the kernel reload so the OLD backend doesn't
        // click against new parameter defaults emitted by `compileAndRun`'s
        // post-load tree rebuild.
        beginPresetTransition()
        defer { endPresetTransition() }
        // `persistManifest: false` honors the documented no-disk-writes
        // contract — `compile_and_run` is an explicit "test this code"
        // intent, not a save. Tree gets rebuilt below via
        // `rebuildParamTreeFromKernelIfChanged` (which is purely
        // in-memory) so the agent sees the new params, but
        // `manifest.json` stays byte-for-byte identical.
        let result = await compileAndRun(source: source, persistManifest: false)
        if result.success {
            mcpLastError = nil
            // After every successful MCP compile_and_run, force the
            // param tree to reflect the kernel's freshly-extracted
            // metadata. Otherwise, when the active preset has a
            // declared `params` block in its manifest (every
            // schemaVersion-2 bundle), `readParamNames()` returns
            // early without rebuilding — the manifest takes priority,
            // by design, so the UI renders correct defaults during a
            // slow Rust compile. But MCP compile_and_run is an
            // explicit "test this new code" intent. Without this
            // explicit rebuild, an agent iterating with a fresh
            // params!() macro sees `success: true` from the compile
            // but `get_parameters` still shows the bundle's old
            // params — the symptom Round 5b's agent worked around
            // by always saving instead of compile_and_run.
            let paramTreeRebuilt = self.rebuildParamTreeFromKernelIfChanged()
            // When compile_and_run produces a new parameter schema (a
            // declared `params!()` macro change), the host-side param tree
            // updates above — but the running custom-UI webview's
            // `<cdp-knob param="…">` bindings were resolved at element
            // mount time against the OLD schema, so any newly-added
            // params render as unbound knobs that look fine but do
            // nothing. The file watcher only reloads on `ui/` file
            // changes, which doesn't help here (no UI file changed).
            // Piggyback on the toolbar's existing manual-reload primitive
            // — same debounced `scheduleReload(webView:)` path — so
            // schema-mutating compiles trigger a webview re-bind without
            // requiring the agent to touch the UI file as a workaround.
            if paramTreeRebuilt {
                NotificationCenter.default.post(name: .reloadCustomUI, object: nil)
            }
            var response: [String: Any] = [
                "success": true,
                "param_tree_rebuilt": paramTreeRebuilt,
            ]
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
    private func mcpGetParameters(input: [String: Any]) -> (String, Bool) {
        let metadata = currentParamMetadata
        let includeUnused = Self.coerceBool(input["include_unused"]) ?? false

        // Default behavior: when the script declares metadata, only
        // surface the declared params. Generic Param 0..15 entries
        // beyond `metadata.count` are kernel slots the script doesn't
        // actually read — surfacing them used to confuse agents into
        // thinking their PARAMS dict had been parsed when it hadn't.
        // Legacy mode (no metadata declared at all) keeps returning
        // all 16 since we can't tell which the script reads.
        let limit: Int
        if let meta = metadata, !includeUnused {
            limit = meta.count
        } else {
            limit = Self.paramCount
        }

        var params: [[String: Any]] = []
        for i in 0..<limit {
            guard let param = parameterTree?.parameter(withAddress: AUParameterAddress(i)) else {
                continue
            }
            let meta = metadata.flatMap { i < $0.count ? $0[i] : nil }
            let style = meta?.style
            let minD = Self.roundForDisplay(Double(param.minValue), range: Double(param.maxValue - param.minValue), style: style)
            let maxD = Self.roundForDisplay(Double(param.maxValue), range: Double(param.maxValue - param.minValue), style: style)
            let valueD = Self.roundForDisplay(Double(param.value), range: Double(param.maxValue - param.minValue), style: style)
            var entry: [String: Any] = [
                "index": i,
                "name": param.displayName,
                "value": valueD,
                "min": minD,
                "max": maxD,
            ]
            if let m = meta {
                entry["unit"] = m.unit
                if let style = m.style { entry["style"] = style }
                if let options = m.options { entry["options"] = options }
                entry["default"] = Self.roundForDisplay(Double(m.default), range: Double(m.max - m.min), style: m.style)
                if let curve = m.curve { entry["curve"] = curve }
            }
            params.append(entry)
        }

        var response: [String: Any] = [
            "parameters": params,
            "count": params.count,
            "total_slots": Self.paramCount,
        ]
        if metadata == nil {
            response["legacy_mode"] = true
        }
        return (jsonStr(response), false)
    }

    /// Round a parameter value to a sensible display precision based on
    /// the parameter's range. Eliminates the
    /// "150.00001525878906 for default 150" cosmetic noise from the
    /// AU's normalize/denormalize roundtrip while preserving meaningful
    /// precision across multiple orders of magnitude.
    ///
    /// Rules:
    /// - toggle / choice / integer styles → integer (rounded)
    /// - range >= 1000 (freq, ms)         → 1 decimal
    /// - range >= 10   (dB, pct, ratio)    → 2 decimals
    /// - range >= 1    (mix, normalized)   → 4 decimals
    /// - range <  1    (fine)               → 6 decimals
    static func roundForDisplay(_ value: Double, range: Double, style: String?) -> Double {
        if let style, style == "toggle" || style == "choice" || style == "integer" {
            return value.rounded()
        }
        let absRange = abs(range)
        let decimals: Int
        if absRange >= 1000 { decimals = 1 }
        else if absRange >= 10 { decimals = 2 }
        else if absRange >= 1 { decimals = 4 }
        else { decimals = 6 }
        let factor = pow(10.0, Double(decimals))
        return (value * factor).rounded() / factor
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
            //
            // Broken bundles (manifest fails to parse, entry script
            // missing, etc.) are kept in the list so users + agents can
            // see them and diagnose, instead of silently disappearing.
            // The shape carries a `broken: true` flag and an `error`
            // string in that case; working bundles match the existing
            // shape exactly (no `broken` / no `error` field).
            if let brokenError = preset.brokenError {
                return [
                    "name": preset.name,
                    "is_factory": preset.isFactory,
                    "language": NSNull(),
                    "has_custom_ui": false,
                    "broken": true,
                    "error": brokenError,
                ]
            }
            let bundle = pm.loadBundle(for: preset)
            return [
                "name": preset.name,
                "is_factory": preset.isFactory,
                "has_custom_ui": bundle?.hasCustomUI ?? false,
                "language": preset.language.rawValue,
            ]
        }
        return (jsonStr(["presets": presetList]), false)
    }

    @MainActor
    private func mcpSavePresetImpl(input: [String: Any]) async -> (String, Bool) {
        guard let name = input["name"] as? String else {
            return (jsonStr(["error": "Missing required parameter: name"]), true)
        }

        // Source precedence: explicit `source` param from the caller >
        // kernel's current scriptSource > error. The explicit-source
        // path lets the agent save from scratchpad state ("make me a
        // compressor") in a single call without a prior
        // compile_and_run. The fallback preserves today's "fork what's
        // loaded" behavior (UI Save As, save from a loaded preset).
        let suppliedSource = input["source"] as? String
        let source = suppliedSource ?? scriptSource
        guard let source else {
            return (
                jsonStr(["error": "Missing `source` parameter and no script is loaded in the kernel yet — pass the DSP source text you want the new preset to contain, or call compile_and_run first to load one."]),
                true
            )
        }

        // Language precedence mirrors source: explicit > detect from
        // source text > kernel's current language.
        let language: ScriptLanguage = {
            if let langStr = input["language"] as? String,
               let parsed = ScriptLanguage(rawValue: langStr) {
                return parsed
            }
            if suppliedSource != nil {
                // New source text — detect from heuristics (fn process
                // = rust, def process = python, etc.) so the bundle's
                // entry extension matches the content.
                return ScriptLanguage.detect(from: source)
            }
            return currentScriptLanguage
        }()

        // Lenient bool parsing: agents (especially Sonnet via the MCP
        // bridge) routinely send `"scaffold_ui": "true"` as a JSON
        // string instead of the schema-declared boolean. The strict
        // `as? Bool` cast silently drops a non-bool to nil → defaulted
        // to false → scaffold became a no-op while the response still
        // looked like success. Accept bool, "true"/"false" (case-
        // insensitive), and 0/1 integers; anything else falls back to
        // the documented `false` default.
        let scaffoldUI = Self.coerceBool(input["scaffold_ui"]) ?? false

        // Optional ui_* overrides for the scaffold path. The agent
        // should pass these when the prompt specifies dimensions (and
        // it almost always does). When omitted, fall back to
        // `defaultScaffoldUI` per-field — that's why the override
        // struct carries Optionals, not concrete values. Only the
        // fields the caller explicitly named are overridden; the rest
        // come from the scaffold default. This lives in the MCP layer
        // (not PresetManager) so non-MCP save paths — SaveAsPopover,
        // factory presets — keep their existing behavior.
        let uiOverrides: PresetManifest.UI? = {
            guard scaffoldUI else { return nil }
            let width = Self.coerceInt(input["ui_width"])
            let height = Self.coerceInt(input["ui_height"])
            let audioFrames = Self.coerceBool(input["ui_audio_frames"])
            if width == nil, height == nil, audioFrames == nil {
                return nil
            }
            return PresetManifest.UI(
                entryHTML: nil,
                width: width,
                height: height,
                fps: nil,
                audioFrames: audioFrames
            )
        }()

        let pm = presetManager

        do {
            let preset = try pm.savePreset(
                name: name, source: source,
                language: language,
                scaffoldUI: scaffoldUI,
                scaffoldUIOverrides: uiOverrides,
                // Agents calling save_preset don't know about prior
                // user content — a name collision is incidental, not an
                // intentional replace. Auto-suffix on cross-language
                // collision so a Rust save can't silently delete a
                // user's Python bundle of the same name (and vice
                // versa). The response's `name` field surfaces the
                // actual saved-as name so callers see the suffix.
                // Caught by 2026-05-08 /try-it sweep, Asana 1214671618931260.
                crossLanguageCollision: .autoSuffix
            )

            // Hold the audio output muted across param-tree mutation +
            // kernel reload. Same reason as `selectPreset`: the OLD
            // backend keeps rendering with the NEW preset's parameter
            // values until the new backend is staged and the swap
            // envelope completes.
            beginPresetTransition()
            defer { endPresetTransition() }

            // CRITICAL: apply the new bundle's manifest params BEFORE
            // setCurrentPreset + compileAndRun. Fresh user bundles have
            // no `params` block in manifest.json, so
            // `resolvedParamMetadata()` returns nil. Passing nil clears
            // the stale `manifestDeclaredMetadata` from the PREVIOUS
            // preset — otherwise `readParamNames()` (called after the
            // kernel reload) sees non-empty manifest metadata, runs the
            // drift validator, and returns early WITHOUT rebuilding the
            // parameter tree. Result: sliders keep showing the previous
            // preset's params (e.g. SVF's cutoff + resonance) even
            // though the kernel runs the new DSP.
            //
            // Same ordering rule as `selectPreset`: apply params before
            // `setCurrentPreset` so SwiftUI's view update (which may
            // recreate CustomUIWebView) sees the right metadata on the
            // first `sendInit`.
            if let newBundle = pm.loadBundle(for: preset) {
                applyManifestParams(newBundle.manifest.resolvedParamMetadata())
            } else {
                applyManifestParams(nil)
            }

            // Switch the plugin to the new bundle so follow-up
            // write_bundle_file calls edit it (instead of continuing
            // to hit "factory is read-only" or "no current preset").
            // Mirrors onSaveAsPreset in AudioUnitViewController.
            pm.setCurrentPreset(preset, source: source)
            // User bundles don't have a factory preset number — clear
            // the DAW's currentPreset so hosts don't show a stale
            // factory name alongside the new user bundle.
            clearDAWCurrentPreset()

            // Always reload the kernel from `source`, mirroring
            // `selectPreset`'s post-state. Even when the kernel already
            // has the same source (because the agent called
            // `compile_and_run` earlier), the param-tree rebuild we
            // just did via `applyManifestParams` can leave the
            // kernel's parameter wiring inconsistent with the new
            // tree — selecting the preset later "fixes" it because
            // selectPreset reloads, but until then audio runs
            // passthrough. Reloading unconditionally costs one
            // compile (WasmCache hit for Rust, ~ms for Python) and
            // guarantees disk + tree + kernel are coherent.
            //
            // On success, fan the new source out to Monaco via
            // `scriptSourceDidChange`. Without this, the editor keeps
            // showing the previous preset's source while the kernel
            // runs the new DSP — the next ⌘R would silently overwrite
            // the agent's change with the stale buffer. Mirrors the
            // explicit publish in the `compile_and_run` MCP dispatch.
            let result = await compileAndRun(source: source)
            let kernelReloaded = result.success
            let kernelError = result.success ? nil : result.error
            if result.success {
                var change = ScriptSourceChange(source: source, origin: .mcp)
                change.processTimeMs = result.processTimeMs
                change.budgetMs = result.budgetMs
                scriptSourceDidChange.send(change)
            }

            // Mirror the kernel-extracted parameter metadata back into
            // `manifest.json`'s `params` block. Before this, the
            // `scaffold_ui=true` path emitted a manifest with a `ui`
            // block but no `params` array, so the very next
            // `write_bundle_file` for `ui/index.html` failed static
            // validation on every named `param=` reference — authors
            // had to hand-write a v2 manifest that duplicated metadata
            // the kernel already knew. The 30-run /try-it battery
            // flagged this as the dominant friction across all three
            // harnesses (claude, gemini, codex) and both languages.
            //
            // We mirror unconditionally on a successful kernel reload
            // (always-overwrite: `manifest.params` is a cache, not an
            // override). The Publisher-driven AVC sync path is NOT
            // used here — `compileAndRun` ran with `persistManifest:
            // false`, and the explicit call below keeps the response
            // payload (`manifest_params_populated`) honest even when
            // the AVC sink isn't subscribed (e.g., headless MCP run).
            //
            // We re-load the bundle from disk first because
            // `pm.savePreset` returned a `Preset` (a thin descriptor),
            // not a `PresetBundle` with a parsed manifest. The
            // round-trip is cheap and avoids stale-cache risk.
            var manifestSyncedFromKernel = false
            var manifestTelemetrySyncedFromKernel = false
            if kernelReloaded,
               let savedBundle = pm.loadBundle(for: preset) {
                let kernelMeta = currentParamMetadata ?? []
                let decls = kernelMeta.map { PresetManifest.ParamDecl(from: $0) }
                do {
                    manifestSyncedFromKernel = try pm.syncManifestParamsFromKernel(
                        for: savedBundle,
                        params: decls
                    )
                    if manifestSyncedFromKernel {
                        // Re-load the bundle so subsequent UI smoke
                        // tests / write_bundle_file calls see the
                        // freshly written manifest.params.
                        if let refreshed = pm.loadBundle(for: preset) {
                            applyManifestParams(refreshed.manifest.resolvedParamMetadata())
                        }
                    }
                } catch {
                    // Manifest-mirror failure shouldn't poison the
                    // whole save_preset call (the bundle and kernel
                    // are already correct). Surface as a warning in
                    // the response and keep going.
                    mcpLog.warning("[save_preset] manifest params mirror failed: \(error.localizedDescription, privacy: .public)")
                }

                // Mirror telemetry too. Same root-cause family as the
                // params sync above (PR #298): without this, an
                // existing-bundle re-save that flips the script's
                // language or drops/renames telemetry slots leaves
                // `manifest.telemetry` stale on disk —
                // `BundleUIValidator` then lints against slot names
                // the new script no longer publishes. The
                // `applyingSaveRewrites` rewrite already cleared the
                // block before disk write; this re-populates it from
                // the freshly-loaded kernel.
                let kernelTelemetry = readKernelTelemetryMetadata() ?? []
                let telemetryDecls = kernelTelemetry.map { PresetManifest.TelemetryDecl(from: $0) }
                // Re-load the bundle to pick up the post-params-sync
                // manifest before the telemetry sync's idempotency
                // check runs against it.
                let bundleForTelemetry = pm.loadBundle(for: preset) ?? savedBundle
                do {
                    manifestTelemetrySyncedFromKernel = try pm.syncManifestTelemetryFromKernel(
                        for: bundleForTelemetry,
                        telemetry: telemetryDecls
                    )
                } catch {
                    mcpLog.warning("[save_preset] manifest telemetry mirror failed: \(error.localizedDescription, privacy: .public)")
                }
            }

            // Top-level `success` reflects the WHOLE atomic operation:
            // disk save AND kernel reload. The bundle was committed to
            // disk and the current preset switched (those are tracked
            // separately via `switched_current_preset` for callers that
            // care to disambiguate), but if the kernel couldn't load
            // the new source then audio is now broken — treating that
            // as `success: true` is misleading and breaks the MCP
            // tool-error contract. `isError` flips with `success` so
            // MCP clients see this as a failed call when the kernel
            // didn't reload.
            //
            // Round 9 of the agent UX experiment caught this: agent
            // saved a preset whose `freq()` call had a bad kwarg, got
            // back `success: true` + populated `kernel_error`, and
            // was confused about whether their preset had really saved.
            // Sentry comment 3142737220 flagged the same shape earlier
            // but was misattributed as "resolved in 84d264c" (which is
            // actually a docs-only commit — the fix never landed).
            var response: [String: Any] = [
                "success": kernelReloaded,
                "name": preset.name,
                "switched_current_preset": true,
                "kernel_reloaded": kernelReloaded,
            ]
            // If the cross-language collision path auto-suffixed the
            // bundle (e.g. Rust save into a name owned by an existing
            // Python bundle), surface that explicitly so the agent
            // doesn't keep referring to the requested name. Compare
            // against the *requested* name pre-sanitize-and-suffix.
            let requestedSanitized = pm.sanitizeFilename(name)
            if preset.name != requestedSanitized {
                response["renamed_from"] = requestedSanitized
                response["rename_reason"] = "A preset named \"\(requestedSanitized)\" already exists in another language; saved as \"\(preset.name)\" instead. The existing bundle was preserved untouched."
            }
            if let err = kernelError {
                response["kernel_error"] = err
            }
            if scaffoldUI {
                response["scaffolded_ui"] = true
                response["note"] = "Starter ui/index.html written. Edit it via write_bundle_file to customize the custom HTML/JS UI."
            }
            if manifestSyncedFromKernel {
                response["manifest_params_populated"] = true
            }
            if manifestTelemetrySyncedFromKernel {
                response["manifest_telemetry_populated"] = true
            }
            return (jsonStr(response), !kernelReloaded)
        } catch {
            return (jsonStr(["error": "Failed to save preset: \(error.localizedDescription)"]), true)
        }
    }

    /// Fork an existing preset bundle (factory or user) by copying the
    /// FULL tree — manifest, ui/, ui/assets/, entry script — to a new
    /// user bundle. Distinct from `save_preset`, which always produces
    /// a stripped-down clone (just the entry script with a default
    /// manifest, no UI/assets carried over).
    ///
    /// Optionally replaces the entry script after copying so the agent
    /// can fork-and-modify in one tool call.
    @MainActor
    private func mcpDuplicateBundleImpl(input: [String: Any]) async -> (String, Bool) {
        guard let sourceName = input["source_name"] as? String, !sourceName.isEmpty else {
            return (jsonStr(["error": "Missing required parameter: source_name"]), true)
        }
        guard let destName = input["dest_name"] as? String, !destName.isEmpty else {
            return (jsonStr(["error": "Missing required parameter: dest_name"]), true)
        }
        let newSource = input["new_source"] as? String

        let pm = presetManager
        guard let sourcePreset = pm.presets.first(where: { $0.name == sourceName }) else {
            return (jsonStr(["error": "No preset named '\(sourceName)'. Use list_presets to see available names."]), true)
        }
        guard let sourceBundle = pm.loadBundle(for: sourcePreset) else {
            return (jsonStr(["error": "Failed to load source bundle '\(sourceName)' from disk."]), true)
        }

        do {
            let preset = try pm.duplicateBundle(
                source: sourceBundle,
                destName: destName,
                replacingEntryWith: newSource
            )

            // Resolve the source FIRST so we can fail-fast on a read
            // error before we mutate any AU-side state (param tree,
            // current preset, kernel).
            //
            // We surface readSource() failures explicitly: a `try?`
            // here would leave runSource empty, skip the kernel
            // reload, and report success: true / kernel_reloaded:
            // false with no explanation — exactly the "guess what
            // went wrong" shape the agent UX experiment told us to
            // avoid. (Earlier shape applied applyManifestParams
            // BEFORE this check, so a read error left the param
            // tree half-mutated even on the success: false return —
            // Sentry flagged that as a partial-state bug.)
            var sourceReadError: String? = nil
            let runSource: String = {
                if let newSource { return newSource }
                guard let bundle = pm.loadBundle(for: preset) else {
                    sourceReadError = "Could not re-load duplicated bundle from disk."
                    return ""
                }
                do {
                    return try bundle.readSource()
                } catch {
                    sourceReadError = "Could not read entry script from duplicated bundle: \(error.localizedDescription)"
                    return ""
                }
            }()
            if let err = sourceReadError {
                return (jsonStr([
                    "success": false,
                    "error": err,
                    "name": preset.name,
                    "switched_current_preset": false,
                    "kernel_reloaded": false,
                ]), true)
            }

            // Hold the audio output muted across param-tree mutation +
            // kernel reload (same reason as `save_preset` / `selectPreset`).
            beginPresetTransition()
            defer { endPresetTransition() }

            // Now safe to mutate AU state. Same param-tree handoff
            // as save_preset: apply the new bundle's manifest params
            // BEFORE switching + reload, so readParamNames doesn't
            // return early on stale priority metadata.
            // duplicate_bundle COPIES the source's manifest, so
            // manifest.params reflects whatever the source declared
            // — that's the correct starting point for the fork.
            if let newBundle = pm.loadBundle(for: preset) {
                applyManifestParams(newBundle.manifest.resolvedParamMetadata())
            } else {
                applyManifestParams(nil)
            }

            pm.setCurrentPreset(preset, source: runSource)
            clearDAWCurrentPreset()

            var kernelReloaded = false
            var kernelError: String? = nil
            if !runSource.isEmpty {
                // `persistManifest: true` so a fork whose `new_source`
                // declares different params from the source bundle's
                // copied manifest auto-rewrites `manifest.params` to
                // match the new kernel metadata. Drives the routed
                // commit through `manifestDriftCorrected` → AVC sink
                // → `gc.recordSave`, same as `selectPreset`.
                let result = await compileAndRun(source: runSource, persistManifest: true)
                kernelReloaded = result.success
                kernelError = result.success ? nil : result.error
                if result.success {
                    var change = ScriptSourceChange(source: runSource, origin: .mcp)
                    change.processTimeMs = result.processTimeMs
                    change.budgetMs = result.budgetMs
                    scriptSourceDidChange.send(change)
                }
            }

            // If the agent supplied a new_source whose param shape
            // differs from the copied manifest's params block, the
            // tree needs to follow — same code path as compile_and_run.
            let paramTreeRebuilt = self.rebuildParamTreeFromKernelIfChanged()
            // Mirror compile_and_run's webview rebind: when the schema
            // changes mid-flight, force a reload so existing
            // <cdp-knob param="…"> bindings re-resolve against the new
            // param tree. Without this, agents iterating with
            // duplicate_bundle + new_source get unbound knobs for any
            // newly-added params until the next bundle reload.
            if paramTreeRebuilt {
                NotificationCenter.default.post(name: .reloadCustomUI, object: nil)
            }

            // Top-level `success` reflects the WHOLE atomic operation
            // (mirrors save_preset b17506e): bundle copy + switch +
            // kernel reload. If the kernel didn't reload, `success`
            // is false and the MCP isError tuple element flips so
            // clients see this as a failed call. The disk copy +
            // current-preset switch are tracked separately
            // (`switched_current_preset`) for callers that want to
            // disambiguate.
            var response: [String: Any] = [
                "success": kernelReloaded,
                "name": preset.name,
                "switched_current_preset": true,
                "kernel_reloaded": kernelReloaded,
                "param_tree_rebuilt": paramTreeRebuilt,
                "source_was_factory": sourcePreset.isFactory,
            ]
            if let err = kernelError {
                response["kernel_error"] = err
            }
            if newSource != nil {
                response["entry_replaced"] = true
            }
            return (jsonStr(response), !kernelReloaded)
        } catch PresetManager.BundleFileError.alreadyExists {
            return (jsonStr(["error": "A preset named '\(destName)' already exists. Pick a different dest_name or delete the existing one first."]), true)
        } catch {
            return (jsonStr(["error": "Failed to duplicate bundle: \(error.localizedDescription)"]), true)
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
        // Two no-bundle cases worth distinguishing for the agent. A bare
        // `bundle: null` has historically left fresh agents guessing
        // whether scratchpad mode is normal, something is broken, or
        // they should call list_presets first. Surface the actual state
        // and a one-line hint so the next tool call is obvious.
        guard let preset = presetManager.currentPreset else {
            // Scratchpad mode. The kernel may or may not have a script
            // loaded; surface that too so the agent knows whether
            // compile_and_run is needed before save_preset.
            let kernelHasScript = scriptSource != nil
            let hint: String
            if kernelHasScript {
                hint = "Scratchpad mode — no preset selected, but the kernel has a script loaded (use get_script to read it). Call save_preset(name, source) to commit it as a new preset, or duplicate_bundle to fork an existing preset and load THAT into the kernel."
            } else {
                hint = "Scratchpad mode — no preset selected and no script loaded. Call list_presets to see available bundles, duplicate_bundle to fork an existing one, or compile_and_run with source text to start authoring."
            }
            return (jsonStr([
                "bundle": NSNull(),
                "state": "scratchpad",
                "kernel_has_script": kernelHasScript,
                "hint": hint,
            ]), false)
        }
        guard let bundle = presetManager.loadBundle(for: preset) else {
            // currentPreset exists but the bundle on disk failed to
            // load. Two sub-cases worth distinguishing:
            //
            //  1. `broken_manifest` — bundle directory is present and
            //     contains a manifest.json, but the manifest fails to
            //     decode (or `entry` points at a missing script). The
            //     agent has a concrete fix path: read manifest.json,
            //     find the bug, write it back. We re-run the loader
            //     here to recover the underlying parse error.
            //  2. `preset_unloadable` — fallback for everything else
            //     (legacy single-file preset, missing root, etc.).
            if let userURL = preset.fileURL {
                if case .broken(_, _, let parseError) =
                    PresetBundle.loadResult(from: userURL) {
                    let manifestPath = userURL
                        .appendingPathComponent(PresetManifest.filename).path
                    return (jsonStr([
                        "bundle": NSNull(),
                        "state": "broken_manifest",
                        "preset_name": preset.name,
                        "is_factory": preset.isFactory,
                        "manifest_path": manifestPath,
                        "error": parseError,
                        "hint": "currentPreset is '\(preset.name)' but its manifest.json (or entry script) is broken. Read the manifest with read_bundle_file('manifest.json'), fix the JSON / `entry` field, and write it back with write_bundle_file. Underlying error: \(parseError)",
                    ]), false)
                }
            }
            return (jsonStr([
                "bundle": NSNull(),
                "state": "preset_unloadable",
                "preset_name": preset.name,
                "is_factory": preset.isFactory,
                "hint": "currentPreset is '\(preset.name)' but its bundle directory can't be loaded — it may be a legacy single-file preset, or its manifest.json is malformed. Use list_presets to verify what's on disk, or pick a different preset.",
            ]), false)
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

        // user_visible_state — what the user is ACTUALLY seeing right
        // now, not just what the bundle declares on disk. Lets the
        // agent detect "I built it correctly but the user is staring
        // at stale kernel code / a Basic UI fallback / an unsaved-edit
        // asterisk" without having to ask.
        var visibility: [String: Any] = [
            "is_modified": presetManager.isModified,
        ]
        let onDiskSource = try? String(contentsOf: bundle.entryScriptURL, encoding: .utf8)
        let kernelInSync: Bool = {
            guard let disk = onDiskSource, let kernel = self.scriptSource else { return false }
            return disk == kernel
        }()
        visibility["kernel_in_sync"] = kernelInSync
        if bundle.hasCustomUI {
            // Only meaningful when a custom UI exists. False = user
            // toggled it off and is looking at the stock slider panel
            // instead.
            visibility["custom_ui_visible"] = CustomUIPreference.read(key: bundle.name)
        }
        var issues: [String] = []
        if presetManager.isModified {
            issues.append("isModified=true: host title bar shows the '*' modified marker; user sees this as 'unsaved changes'.")
        }
        if !kernelInSync {
            issues.append("Kernel-loaded script differs from the bundle's entry script on disk; audio is running stale code. Call save_preset (or compile_and_run with the on-disk source) to resync.")
        }
        if bundle.hasCustomUI, CustomUIPreference.read(key: bundle.name) == false {
            issues.append("Bundle ships a custom UI but the user has toggled it off; they're seeing the stock slider panel instead. The user can flip the toggle in the host UI's Custom UI bar.")
        }
        visibility["issues"] = issues
        bundleInfo["user_visible_state"] = visibility

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

        // Pre-flight validation for manifest.json writes. A malformed
        // manifest or one pointing at a missing `entry` file makes
        // `PresetBundle.load` return nil — the bundle silently becomes
        // unloadable, `get_bundle_info` reports `bundle: null`, and the
        // agent perceives the preset as "dropped" even though
        // `currentPreset` is still set. Catching the bad write here
        // means the file never lands in a broken state, and the agent
        // gets an actionable error instead of a mysterious unload.
        if url.lastPathComponent == PresetManifest.filename {
            if let errorMessage = PresetManifest.validateProposedWrite(
                content: content,
                bundleRoot: url.deletingLastPathComponent()
            ) {
                return (jsonStr(["error": errorMessage]), true)
            }
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
        // Any bundle file write can flip what the host UI sees: a
        // manifest edit can add/remove the `ui` block; writing
        // ui/index.html for the first time (after manifest already
        // declared `ui`) lands the file `hasCustomUI` is gated on; a
        // ui/assets/* write doesn't change hasCustomUI but does
        // affect what the live webview will reload. Refresh in all
        // cases — re-enumerating the user presets dir + re-parsing
        // the current manifest is cheap, and it guarantees
        // `presetManager.currentBundle` reflects the on-disk state
        // before the agent's next tool call (or the user's next
        // glance at the toggle bar) reads it.
        presetManager.refreshPresets()

        let pathStr = (input["path"] as? String) ?? ""

        // When the write lands the entry script payload, treat it as
        // an explicit save — the disk now equals what the kernel will
        // see on the next compile_and_run, so the dirty-flag baseline
        // (`loadedSource`) needs to follow. Otherwise the canonical
        // agent flow (write entry, then compile_and_run with the same
        // text) flips isModified=true on the downstream
        // scriptSourceDidChange echo. Look up the entry path on the
        // refreshed bundle so an in-the-same-call manifest write that
        // changed `entry` is honored.
        let refreshedBundle = presetManager.currentPreset.flatMap {
            presetManager.loadBundle(for: $0)
        }
        if let refreshedBundle, pathStr == refreshedBundle.manifest.entry {
            presetManager.markEntryScriptSaved(content)
        }

        // For edits that could affect the custom UI (ui/*, manifest.json),
        // run the static validator and include its report in the response
        // so the agent sees warnings on the same turn it wrote the file —
        // no separate tool call required for the common case.
        //
        // Also run on entry-script writes (process.py / process.rs) so
        // STATE-key removals surface as orphaned UI references at the
        // moment of the script edit, rather than on the next compile or
        // smoke test. The validator inspects manifest + ui/* against the
        // bundle's declared state keys; an entry-script edit that drops
        // a STATE key invalidates any `ConjureDSP.state.get/set('foo')`
        // reference in the UI HTML/JS.
        var response: [String: Any] = [
            "success": true,
            "path": input["path"] ?? "",
            "bytes_written": content.utf8.count,
        ]
        let isEntryScript = pathStr == "process.py" || pathStr == "process.rs"
            || (refreshedBundle.map { pathStr == $0.manifest.entry } ?? false)
        let touchesUISurface = pathStr.hasPrefix("ui/")
            || pathStr == PresetManifest.filename
            || url.lastPathComponent == PresetManifest.filename
            || isEntryScript
        if touchesUISurface, let refreshedBundle {
            response["validation"] = validationReportAsJSON(BundleUIValidator.validate(refreshedBundle))
        }
        return (jsonStr(response), false)
    }

    @MainActor
    private func mcpSmokeTestUI() async -> (String, Bool) {
        mcpLog.info("[uaf-trace] smoke_test_ui.enter")
        defer { mcpLog.info("[uaf-trace] smoke_test_ui.exit") }
        guard let preset = presetManager.currentPreset,
              let bundle = presetManager.loadBundle(for: preset) else {
            return (jsonStr(["error": "No current preset with a loadable bundle."]), true)
        }
        guard bundle.hasCustomUI else {
            return (jsonStr([
                "status": "pass",
                "note": "Bundle has no custom UI; nothing to smoke-test.",
            ]), false)
        }

        // `currentParamNames` is [Int: String]? — the kernel/manifest
        // fills it in, may be nil before any preset loads.
        let names = currentParamNames ?? [:]
        let count = ConjureDSPExtensionAudioUnit.paramCount

        let report = await BundleUISmokeTester.run(
            bundle: bundle,
            hostParameterNames: names,
            hostParameterCount: count
        )
        return (encodeReport(report), false)
    }

    // MARK: - dsp_probe

    /// Render the loaded DSP script offline against a synthesized test signal.
    /// Reuses the live kernel (Python's single shared interpreter forces this —
    /// a second kernel would race the live one's `sys.modules` state). Mutes
    /// audio output via the preset-transition envelope while the probe is
    /// running, then reloads the script to reset DSP state (filter histories,
    /// delay buffers) so test-signal residue doesn't bleed into reverb tails.
    @MainActor
    private func mcpDspProbe(input: [String: Any]) async -> (String, Bool) {
        // Parse signal kind.
        guard let signalRaw = input["signal"] as? String else {
            return (jsonStr(["error": "Missing required parameter: signal"]), true)
        }
        let signal: DSPProbe.Signal
        switch signalRaw.lowercased() {
        case "sine":
            let freq = (input["freq_hz"] as? Double)
                ?? (input["freq_hz"] as? Int).map(Double.init)
                ?? 1000.0
            guard freq > 0, freq.isFinite else {
                return (jsonStr(["error": "freq_hz must be positive and finite"]), true)
            }
            signal = .sine(freqHz: freq)
        case "impulse":
            signal = .impulse
        case "silence":
            signal = .silence
        default:
            return (jsonStr(["error": "Unknown signal: \(signalRaw). Use sine, impulse, or silence."]), true)
        }

        // Parse + clamp duration / amplitude.
        let rawDuration = (input["duration_ms"] as? Int)
            ?? (input["duration_ms"] as? Double).map(Int.init)
            ?? 500
        let durationMs = max(50, min(5000, rawDuration))

        let rawAmp = (input["amplitude"] as? Double)
            ?? (input["amplitude"] as? Int).map(Double.init)
            ?? 0.5
        let amplitude = max(0.0, min(1.0, rawAmp))

        // Source is needed for the post-probe reload that restores clean
        // DSP state. Without a loaded source the kernel is in passthrough
        // and has no internal state to restore — skip the reload in that case.
        let source = self.scriptSource
        let language = self.currentScriptLanguage

        // Read live audio config.
        let sampleRate = self.outputBusses[0].format.sampleRate
        guard sampleRate >= 8000, sampleRate.isFinite else {
            return (jsonStr(["error": "Live kernel sample rate (\(sampleRate)) is invalid. Allocate render resources first."]), true)
        }
        let channels = max(1, Int(self.outputBusses[0].format.channelCount))
        let blockSize = max(1, Int(self.maximumFramesToRender))

        guard let kernelRef = self.kernelReference else {
            return (jsonStr(["error": "Kernel is not initialized."]), true)
        }

        // NOTE: we do NOT wrap the probe in begin/endPresetTransition. That
        // mute envelope is applied to the output of every dsp_kernel_process
        // call regardless of caller — including ours. For continuous signals
        // (sine) it only biases the first ~5 ms; for an impulse (whose entire
        // response lives in those first samples) it would silence the output
        // completely. So the probe runs against the bare backend. The audio
        // thread Mutex-contends with us per block — if a DAW is playing
        // audio through the AU at probe time, the user may hear a brief
        // glitch and any reverb/delay state will be polluted by the test
        // signal until the post-probe reload runs.
        let result: DSPProbe.Result = await Task.detached(priority: .userInitiated) {
            DSPProbe.run(
                kernel: kernelRef,
                signal: signal,
                sampleRate: sampleRate,
                channels: channels,
                blockSize: blockSize,
                durationMs: durationMs,
                amplitude: amplitude
            )
        }.value

        // Reload to reset filter/delay/LFO state polluted by the probe's
        // test-signal samples. Wrap THIS step in the transition envelope
        // so the brief backend swap doesn't click. Skip the reload when
        // there's no cached source — the kernel is in passthrough, no
        // state to reset.
        if let source = source {
            dsp_kernel_begin_preset_transition(kernelRef)
            switch language {
            case .python:
                _ = self.reloadScript(source: source, persistManifest: false)
            case .rust:
                if let bytes = self.wasmBytes {
                    _ = self.loadWasm(bytes: bytes, persistManifest: false)
                } else {
                    _ = await self.compileAndRun(source: source, persistManifest: false)
                }
            }
            dsp_kernel_end_preset_transition(kernelRef)
        }

        let response: [String: Any] = [
            "signal": result.signal.name,
            "sample_rate": result.sampleRate,
            "channel_count": result.channelCount,
            "frames": result.frames,
            "block_size": result.blockSize,
            "in_rms": Double(result.inStats.rms),
            "out_rms": Double(result.outStats.rms),
            "in_peak": Double(result.inStats.peak),
            "out_peak": Double(result.outStats.peak),
            "out_dc": Double(result.outStats.dc),
            "has_nan": result.outStats.hasNaN,
            "has_inf": result.outStats.hasInf,
        ]
        return (jsonStr(response), false)
    }

    /// Structured Codable → [String: Any] → jsonStr. Keeps the MCP
    /// response wire format consistent with the other handlers that
    /// build dicts by hand.
    private func encodeReport<T: Encodable>(_ report: T) -> String {
        do {
            let data = try JSONEncoder().encode(report)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return jsonStr(["error": "Report serialization produced non-object JSON"])
            }
            return jsonStr(obj)
        } catch {
            return jsonStr(["error": "Report encode failed: \(error.localizedDescription)"])
        }
    }

    // MARK: - State Channel (bundle-private STATE)

    /// Set a single key in the bundle-private STATE channel. Strict-mode:
    /// rejects unknown keys (i.e. keys not declared in the script's
    /// `STATE = {…}` defaults dict) so authors don't accidentally write
    /// to a misspelled key and wonder why the audio thread never sees it.
    @MainActor
    private func mcpSetState(input: [String: Any]) -> (String, Bool) {
        guard let key = input["key"] as? String else {
            return (jsonStr(["error": "Missing required parameter: key"]), true)
        }
        // `value` may be any JSON type, including NSNull (delete). Read it
        // verbatim — the manager handles the type discriminator.
        let value = input["value"]

        let mgr = presetStateManager
        let declared = mgr.declaredKeys
        if !declared.isEmpty, !declared.contains(key) {
            return (jsonStr([
                "ok": false,
                "reason": "unknown_key",
                "available_keys": declared,
            ]), true)
        }
        let ok = mgr.set(key: key, value: value, origin: .mcp)
        if !ok {
            return (jsonStr([
                "ok": false,
                "reason": "size_exceeded",
                "max_bytes": mgr.maxBytes,
            ]), true)
        }
        return (jsonStr([
            "ok": true,
            "generation": Int(mgr.generation),
        ]), false)
    }

    /// Read the current STATE mirror. With `key`, returns just that
    /// value (or NSNull if absent). Without, returns the full dict.
    @MainActor
    private func mcpGetState(input: [String: Any]) -> (String, Bool) {
        let mgr = presetStateManager
        let snapshot = mgr.snapshotForInit()
        if let key = input["key"] as? String {
            let value = snapshot[key] ?? NSNull()
            return (jsonStr([
                "ok": true,
                "value": value,
            ]), false)
        }
        return (jsonStr([
            "ok": true,
            "state": snapshot,
            "declared_keys": mgr.declaredKeys,
            "max_bytes": mgr.maxBytes,
            "generation": Int(mgr.generation),
        ]), false)
    }

    /// Reset a single key (or the whole mirror when `key` is omitted)
    /// back to the script's declared defaults.
    @MainActor
    private func mcpResetState(input: [String: Any]) -> (String, Bool) {
        let mgr = presetStateManager
        let key = input["key"] as? String
        let ok = mgr.reset(key: key, origin: .mcp)
        return (jsonStr([
            "ok": ok,
            "generation": Int(mgr.generation),
        ]), false)
    }

    @MainActor
    private func mcpValidateBundle() -> (String, Bool) {
        guard let preset = presetManager.currentPreset else {
            return (jsonStr(["error": "No current preset."]), true)
        }
        guard let bundle = presetManager.loadBundle(for: preset) else {
            return (jsonStr(["error": "Could not load bundle for current preset."]), true)
        }
        let report = BundleUIValidator.validate(bundle)
        return (jsonStr(validationReportAsJSON(report)), false)
    }

    /// JSON-friendly shape for inclusion in tool responses. Mirrors
    /// `BundleUIValidator.Report` — kept explicit because `jsonStr` works
    /// on `[String: Any]`, not `Encodable`.
    private func validationReportAsJSON(_ report: BundleUIValidator.Report) -> [String: Any] {
        let issues: [[String: Any]] = report.issues.map { issue in
            var d: [String: Any] = [
                "severity": issue.severity.rawValue,
                "check": issue.check,
                "message": issue.message,
            ]
            if let file = issue.file { d["file"] = file }
            if let suggestion = issue.suggestion { d["suggestion"] = suggestion }
            return d
        }
        return [
            "status": report.status.rawValue,
            "issues": issues,
        ]
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

        let validTopics = ["params", "filters", "delays", "oscillators", "utilities", "accel", "nam", "state", "ui", "all"]
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
        if topic == "state" || topic == "all" { sections.append(DSPDocumentation.state) }
        if topic == "ui" || topic == "all" { sections.append(DSPDocumentation.ui) }

        // PR #5: append auto-extracted API reference for library-backed topics.
        // Hand-curated content above + extractor output below. Graceful: if
        // source files aren't bundled or extraction yields nothing, this is
        // a no-op and the hand-curated text ships unchanged.
        let libraryBackedTopics = ["filters", "delays", "oscillators", "utilities", "accel", "nam"]
        if topic == "all" {
            for t in libraryBackedTopics {
                if let appendix = DSPDocumentation.apiReferenceAppendix(for: t) {
                    sections.append(appendix)
                }
            }
        } else if libraryBackedTopics.contains(topic),
                  let appendix = DSPDocumentation.apiReferenceAppendix(for: topic) {
            sections.append(appendix)
        }

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

    /// Coerce an MCP tool input value into a Bool, accepting the shapes
    /// agents commonly send through JSON-RPC even when the schema
    /// declares `type: "boolean"`. Returns nil when the value isn't
    /// recognizable as a boolean — callers fall back to the documented
    /// default.
    ///
    /// Accepted shapes:
    ///  - native `Bool` (the schema-correct path)
    ///  - `"true"` / `"false"` / `"yes"` / `"no"` / `"1"` / `"0"` strings
    ///    (case-insensitive, trimmed)
    ///  - `0` / `1` numbers (Int or Double)
    ///
    /// Why coerce instead of strict-rejecting: a /try-it sweep on
    /// 2026-05-08 caught Sonnet routinely sending `"scaffold_ui": "true"`
    /// as a JSON string. The strict `as? Bool` cast returned nil, the
    /// `?? false` default kicked in, and `save_preset` silently produced
    /// a bundle without the requested ui scaffold while the response
    /// payload still read like success. The agent then hand-authored
    /// the manifest+ui block from scratch (as observed in runs 01, 07,
    /// 09 of the sweep). Coercion is the minimum-friction fix; a
    /// stricter error would help diagnose but breaks more agents than
    /// it helps.
    static func coerceBool(_ value: Any?) -> Bool? {
        switch value {
        case let b as Bool:
            return b
        case let s as String:
            switch s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        case let i as Int:
            if i == 0 { return false }
            if i == 1 { return true }
            return nil
        case let d as Double:
            if d == 0.0 { return false }
            if d == 1.0 { return true }
            return nil
        default:
            return nil
        }
    }

    /// Same lenient-coercion shape as `coerceBool` but for integer args.
    /// Agents commonly send numeric args as JSON strings ("360") or as
    /// Double-valued JSON numbers; both should land as Int. Returns nil
    /// if the value is missing or can't be unambiguously interpreted.
    static func coerceInt(_ value: Any?) -> Int? {
        // Reject Bool explicitly BEFORE matching Int. Foundation bridges
        // `NSNumber(value: true)` to both `as? Bool` (true) and
        // `as? Int` (1), so without this guard `coerceInt(true)` would
        // silently land as 1 — surprising for a caller expecting the
        // schema-declared integer type to reject a boolean.
        if value is Bool { return nil }

        switch value {
        case let i as Int:
            return i
        case let d as Double:
            // Reject obviously-fractional doubles — the schema declares
            // integer, so 280.5 is more likely a bug than a rounding
            // request.
            if d.rounded() == d, d >= Double(Int.min), d <= Double(Int.max) {
                return Int(d)
            }
            return nil
        case let s as String:
            return Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }
}
