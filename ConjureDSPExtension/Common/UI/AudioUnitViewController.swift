//
//  AudioUnitViewController.swift
//  ConjureDSPExtension
//
//  Created by Michael Jancsy on 2/25/26.
//

import Combine
import CoreAudioKit
import os
import SwiftUI

private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSPExtension", category: "AudioUnitViewController")

// MARK: - SafeHostingView

/// NSHostingView subclass that guards against the macOS 14+ ViewBridge bug
/// where `NSViewServiceMarshal` fails to render a second AUv3 ViewController
/// in the same extension process. When the old VC's hosting view is removed
/// from its window, `viewDidMoveToWindow()` with `window == nil` would tear
/// down SwiftUI's rendering pipeline. Skipping `super` in that case prevents
/// interference with the new VC's view.
private class SafeHostingView<Content: View>: NSHostingView<Content> {
    override func viewDidMoveToWindow() {
        if self.window != nil {
            super.viewDidMoveToWindow()
        }
        // When window is nil (VC being torn down), skip super to avoid
        // SwiftUI rendering teardown that interferes with the new VC.
    }
}

@MainActor
public class AudioUnitViewController: AUViewController, AUAudioUnitFactory {
    private static var sentryStarted = false

    var audioUnit: AUAudioUnit? {
        didSet {
            log.info("audioUnit didSet, isViewLoaded=\(self.isViewLoaded, privacy: .public)")
        }
    }

    private var hostingView: SafeHostingView<ConjureDSPExtensionMainView>?
    private var aiService: AIService?
    private var chatService: ChatService?
    private var captureManager: AudioCaptureManager?
    private var parameterState: ParameterState?
    private var licenseManager: LicenseManager?
    private var gitHubService: GitHubService?
    private var paramNamesCancellable: AnyCancellable?
    private var paramMetadataCancellable: AnyCancellable?

	deinit {
        log.info("deinit called")
	}

    /// Provide a fresh NSView container each time the system creates this VC.
    /// This forces the ViewBridge to work with a new view hierarchy, working
    /// around the NSViewServiceMarshal bug in macOS 14+ where a second VC
    /// in the same extension process fails to render.
    public override var preferredMinimumSize: NSSize {
        NSSize(width: 400, height: 300)
    }

    public override var preferredMaximumSize: NSSize {
        NSSize(width: 2560, height: 1600)
    }

    public override func loadView() {
        if !Self.sentryStarted {
            SentrySetup.start()
            Self.sentryStarted = true
        }

        let screen = NSScreen.main ?? NSScreen.screens.first
        let defaultSize: NSSize
        if let screenFrame = screen?.visibleFrame {
            defaultSize = NSSize(
                width: round(screenFrame.width * 0.7),
                height: round(screenFrame.height * 0.8)
            )
        } else {
            defaultSize = NSSize(width: 960, height: 800)
        }
        self.view = NSView(frame: NSRect(origin: .zero, size: defaultSize))
        self.preferredContentSize = defaultSize
        log.info("loadView called")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        log.info("viewDidLoad called, audioUnit=\(self.audioUnit == nil ? "nil" : "set", privacy: .public)")
    }

    public override func viewWillAppear() {
        super.viewWillAppear()
        log.info("viewWillAppear called, hostingView=\(self.hostingView == nil ? "nil" : "set", privacy: .public)")
        guard let audioUnit = self.audioUnit else { return }
        if hostingView == nil || hostingView?.superview == nil {
            // Dispatch async to let the ViewBridge finish connecting the
            // view service before we add the NSHostingView.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                log.info("configureSwiftUIView (async from viewWillAppear)")
                self.configureSwiftUIView(audioUnit: audioUnit)
            }
        }
    }

	nonisolated public func createAudioUnit(with componentDescription: AudioComponentDescription) throws -> AUAudioUnit {
		return try DispatchQueue.main.sync {
			log.info("createAudioUnit called")

			audioUnit = try ConjureDSPExtensionAudioUnit(componentDescription: componentDescription, options: [])

			guard let audioUnit = self.audioUnit as? ConjureDSPExtensionAudioUnit else {
				log.error("Unable to create ConjureDSPExtensionAudioUnit")
				return audioUnit!
			}

			return audioUnit
		}
	}

    private func configureSwiftUIView(audioUnit: AUAudioUnit) {
        log.info("configureSwiftUIView called")
        Analytics.initialize()

        hostingView?.removeFromSuperview()

        guard let au = audioUnit as? ConjureDSPExtensionAudioUnit else {
            log.error("audioUnit is not ConjureDSPExtensionAudioUnit")
            return
        }

        let pm = au.presetManager

        // Use restored script from fullState if available, otherwise select the default factory preset
        let initialScript: String
        let initialLanguage: ScriptLanguage
        let initialBenchmark: (processTimeMs: Double, budgetMs: Double)?
        if let restored = au.scriptSource {
            initialScript = restored
            initialLanguage = au.currentScriptLanguage
            // If no preset is selected yet (fresh launch, not a fullState restore with a preset),
            // select the default factory preset in the preset manager
            if pm.currentPreset == nil,
               let defaultPreset = pm.presets.first(where: { preset in
                   guard case .factory(let name) = preset.source else { return false }
                   return name == ConjureDSPExtensionAudioUnit.defaultPresetResource
               }) {
                pm.setCurrentPreset(defaultPreset, source: restored)
            }
            // Benchmark the already-loaded script so the UI shows timing
            let benchSecs = dsp_kernel_benchmark_process(au.kernelReference)
            if benchSecs >= 0 {
                let processTimeMs = benchSecs * 1000.0
                let sampleRate = au.outputBusses[0].format.sampleRate > 0 ? au.outputBusses[0].format.sampleRate : 44100.0
                let maxFrames = Double(au.maximumFramesToRender > 0 ? au.maximumFramesToRender : 512)
                let budgetMs = maxFrames / sampleRate * 1000.0
                initialBenchmark = (processTimeMs, budgetMs)
            } else {
                initialBenchmark = nil
            }
        } else {
            initialScript = "# Default preset not found in bundle\n"
            initialLanguage = .python
            initialBenchmark = nil
        }

        if aiService == nil {
            aiService = AIService()
        }
        let ai = aiService!

        if chatService == nil {
            chatService = ChatService(aiService: ai)
        }
        let chat = chatService!
        chat.toolExecutor.audioUnit = au
        chat.toolExecutor.presetManager = pm
        chat.toolExecutor.onScriptChanged = { [weak au] source, processTimeMs, budgetMs in
            au?.scriptSourceDidChange.send(
                ConjureDSPExtensionAudioUnit.ScriptSourceChange(
                    source: source, processTimeMs: processTimeMs, budgetMs: budgetMs
                )
            )
        }

        if captureManager == nil {
            captureManager = AudioCaptureManager()
        }
        let capture = captureManager!
        capture.kernel = au.kernelReference
        capture.hostView = self.view

        if parameterState == nil {
            parameterState = ParameterState()
        }
        let ps = parameterState!
        if let tree = au.parameterTree {
            ps.attach(to: tree)
        }
        // Set initial param names and metadata from the currently loaded script
        if let au = au as? ConjureDSPExtensionAudioUnit {
            ps.paramNames = au.currentParamNames
            ps.paramMetadata = au.currentParamMetadata
            paramNamesCancellable = au.paramNamesDidChange
                .receive(on: DispatchQueue.main)
                .sink { [weak ps] names in
                    ps?.paramNames = names
                }
            paramMetadataCancellable = au.paramMetadataDidChange
                .receive(on: DispatchQueue.main)
                .sink { [weak ps, weak au] metadata in
                    ps?.paramMetadata = metadata
                    // Re-attach to the parameter tree since it was rebuilt
                    if let tree = au?.parameterTree {
                        ps?.attach(to: tree)
                    }
                }
        }

        if licenseManager == nil {
            licenseManager = LicenseManager()
        }
        let lm = licenseManager!

        if gitHubService == nil {
            gitHubService = GitHubService()
        }
        let gh = gitHubService!
        gh.wireAutoSync(presetManager: pm)
        gh.syncIfConnected(presetManager: pm)
        lm.verifyWithKernel = { [weak au] serial in
            au?.verifyLicense(serial) ?? false
        }
        lm.getDemoSecondsRemaining = { [weak au] in
            au?.demoSecondsRemaining() ?? 0
        }
        lm.resetDemoInKernel = { [weak au] in
            au?.resetDemo()
        }
        lm.loadAndVerify()

        // Run: detect language, compile if needed, load into kernel + benchmark
        let onRun: (String) async -> ScriptSaveResult = { [weak au] source in
            guard let au else {
                return ScriptSaveResult(success: false, error: "Audio unit not available", processTimeMs: nil, budgetMs: nil)
            }
            let result = await au.compileAndRun(source: source)
            Analytics.track(.scriptRun, properties: [
                "language": ScriptLanguage.detect(from: source).rawValue,
                "success": result.success,
            ])
            return ScriptSaveResult(success: result.success, error: result.error, processTimeMs: result.processTimeMs, budgetMs: result.budgetMs)
        }

        // Select preset: load into kernel + update preset manager
        let onSelectPreset: (Preset) async -> ScriptSaveResult = { [weak au] preset in
            guard let au else {
                return ScriptSaveResult(success: false, error: "Audio unit not available", processTimeMs: nil, budgetMs: nil)
            }
            let result = await au.selectPreset(preset)
            Analytics.track(.presetLoad, properties: [
                "preset_name": preset.name,
                "preset_type": preset.isFactory ? "factory" : "user",
                "language": preset.language.rawValue,
            ])
            return result
        }

        // Save: overwrite current user/repo preset + hot-reload
        let onSavePreset: (String, ScriptLanguage) -> ScriptSaveResult = { [weak au, weak pm] source, language in
            guard let au, let pm else {
                return ScriptSaveResult(success: false, error: "Audio unit not available", processTimeMs: nil, budgetMs: nil)
            }
            guard let current = pm.currentPreset, !current.isFactory else {
                return ScriptSaveResult(success: false, error: "No user preset selected", processTimeMs: nil, budgetMs: nil)
            }
            do {
                let saved: Preset
                if current.isRepo {
                    saved = try pm.saveRepoPreset(name: current.name, source: source, language: language)
                } else {
                    saved = try pm.saveUserPreset(name: current.name, source: source, language: language)
                }
                Analytics.track(.presetSave, properties: [
                    "preset_name": current.name,
                    "is_new": false,
                    "language": language.rawValue,
                ])
                Analytics.flush()
                switch language {
                case .python:
                    let result = au.reloadScript(source: source)
                    pm.setCurrentPreset(saved, source: source)
                    return ScriptSaveResult(success: result.success, error: result.error, processTimeMs: result.processTimeMs, budgetMs: result.budgetMs)
                case .rust:
                    au.currentScriptLanguage = .rust
                    pm.setCurrentPreset(saved, source: source)
                    return ScriptSaveResult(success: true, error: nil, processTimeMs: nil, budgetMs: nil)
                }
            } catch {
                return ScriptSaveResult(success: false, error: error.localizedDescription, processTimeMs: nil, budgetMs: nil)
            }
        }

        // Save As: create new preset (repo if connected, else user) + hot-reload
        let onSaveAsPreset: (String, String, ScriptLanguage) -> ScriptSaveResult = { [weak au, weak pm, weak gh] name, source, language in
            guard let au, let pm else {
                return ScriptSaveResult(success: false, error: "Audio unit not available", processTimeMs: nil, budgetMs: nil)
            }
            do {
                let saved: Preset
                if let gh, gh.hasPersonalRepo, gh.hasToken {
                    saved = try pm.saveRepoPreset(name: name, source: source, language: language)
                } else {
                    saved = try pm.saveUserPreset(name: name, source: source, language: language)
                }
                Analytics.track(.presetSave, properties: [
                    "preset_name": name,
                    "is_new": true,
                    "language": language.rawValue,
                ])
                Analytics.flush()
                switch language {
                case .python:
                    let result = au.reloadScript(source: source)
                    pm.setCurrentPreset(saved, source: source)
                    return ScriptSaveResult(success: result.success, error: result.error, processTimeMs: result.processTimeMs, budgetMs: result.budgetMs)
                case .rust:
                    au.currentScriptLanguage = .rust
                    pm.setCurrentPreset(saved, source: source)
                    return ScriptSaveResult(success: true, error: nil, processTimeMs: nil, budgetMs: nil)
                }
            } catch {
                return ScriptSaveResult(success: false, error: error.localizedDescription, processTimeMs: nil, budgetMs: nil)
            }
        }

        // Delete: remove current user preset
        let onDeletePreset: () -> Void = { [weak pm] in
            guard let pm, let current = pm.currentPreset, !current.isFactory else { return }
            try? pm.deleteUserPreset(current)
        }

        // New: reset to default template for the selected language
        let extensionBundle = Bundle(for: type(of: self))
        log.info("Extension bundle path: \(extensionBundle.bundlePath, privacy: .public)")
        let onNew: (ScriptLanguage) -> ScriptSaveResult = { [weak au, weak pm] language in
            guard let au, let pm else {
                return ScriptSaveResult(success: false, error: "Audio unit not available", processTimeMs: nil, budgetMs: nil)
            }
            let ext = language == .rust ? "rs" : "py"
            guard let url = extensionBundle.url(forResource: "process", withExtension: ext),
                  let source = try? String(contentsOf: url, encoding: .utf8) else {
                return ScriptSaveResult(success: false, error: "Default \(language.rawValue) template not found", processTimeMs: nil, budgetMs: nil)
            }
            switch language {
            case .python:
                let result = au.reloadScript(source: source)
                pm.setCurrentPreset(nil, source: source)
                au.scriptSourceDidChange.send(ConjureDSPExtensionAudioUnit.ScriptSourceChange(source: source))
                return ScriptSaveResult(success: result.success, error: result.error, processTimeMs: result.processTimeMs, budgetMs: result.budgetMs)
            case .rust:
                // Don't compile on New — just show the template
                au.currentScriptLanguage = .rust
                pm.setCurrentPreset(nil, source: source)
                au.scriptSourceDidChange.send(ConjureDSPExtensionAudioUnit.ScriptSourceChange(source: source))
                return ScriptSaveResult(success: true, error: nil, processTimeMs: nil, budgetMs: nil)
            }
        }

        // Export: assemble standalone AU .app
        // Strategy: try direct export with signing first (works in unsandboxed host app).
        // If that fails (e.g. sandbox blocks Process()), fall back to App Group staging
        // for the host app to finalize later.
        //
        // Note: AUv3 view controllers run in a ViewBridge XPC process even when the
        // audio unit is loaded in-process, so Bundle.main is NOT the host app's bundle.
        // Identity-based host detection doesn't work — use capability-based detection instead.
        let onExport: (String) async -> ExportResult = { [weak au] name in
            guard let au else {
                return .error("Audio unit not available")
            }
            guard let source = au.scriptSource else {
                return .error("No script loaded")
            }
            let language = au.currentScriptLanguage
            let wasmData = au.wasmBytes

            if language == .rust && wasmData == nil {
                return .error("Rust preset must be compiled first. Click Run before exporting.")
            }

            guard let templateURL = extensionBundle.url(forResource: "ExportTemplate", withExtension: "zip") else {
                log.error("ExportTemplate.zip not found in bundle at: \(extensionBundle.bundlePath, privacy: .public)")
                return .error("Export template not found in bundle. Rebuild the project.")
            }
            log.info("ExportTemplate.zip path: \(templateURL.path, privacy: .public)")
            if let attrs = try? FileManager.default.attributesOfItem(atPath: templateURL.path),
               let size = attrs[.size] as? Int {
                log.info("ExportTemplate.zip size: \(size, privacy: .public) bytes")
            }

            // Stage unsigned export in App Group — host app finalizes (signs, registers, reveals)
            guard let outputDir = ExportManager.appGroupContainerURL() else {
                return .error("Export failed. App Group container not available — check entitlements.")
            }

            let exportDir = outputDir.appendingPathComponent("PendingExports")
            try? FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)

            do {
                let exportManager = ExportManager()
                let appURL = try exportManager.exportPreset(
                    name: name,
                    source: source,
                    wasmData: wasmData,
                    language: language,
                    templateURL: templateURL,
                    outputDirectory: exportDir,
                    skipSigning: true,
                    paramNames: au.currentParamNames,
                    paramMetadata: au.currentParamMetadata
                )
                log.info("Staged preset '\(name, privacy: .public)' to App Group at \(appURL.path, privacy: .public)")
                Analytics.track(.export, properties: [
                    "name": name,
                    "language": language.rawValue,
                    "success": true,
                ])
                Analytics.flush()
                return .success("Exported \"\(name)\"! Open ConjureDSP to install.")
            } catch {
                log.error("Export failed: \(error.localizedDescription, privacy: .public)")
                Analytics.track(.export, properties: [
                    "name": name,
                    "language": language.rawValue,
                    "success": false,
                ])
                Analytics.flush()
                return .error(error.localizedDescription)
            }
        }

        let scriptPublisher = au.scriptSourceDidChange
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()

        let buildID = extensionBundle.infoDictionary?["BuildID"] as? Int ?? 0

        let content = ConjureDSPExtensionMainView(
            buildID: buildID,
            defaultScriptSource: initialScript,
            defaultLanguage: initialLanguage,
            extensionBundle: extensionBundle,
            scriptSourcePublisher: scriptPublisher,
            presetManager: pm,
            aiService: ai,
            chatService: chat,
            captureManager: capture,
            parameterState: ps,
            licenseManager: lm,
            gitHubService: gh,
            onRun: onRun,
            onSelectPreset: onSelectPreset,
            onSavePreset: onSavePreset,
            onSaveAsPreset: onSaveAsPreset,
            onDeletePreset: onDeletePreset,
            onNew: onNew,
            onExport: onExport,
            defaultBenchmark: initialBenchmark
        )
        let hv = SafeHostingView(rootView: content)
        hv.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(hv)
        NSLayoutConstraint.activate([
            hv.topAnchor.constraint(equalTo: self.view.topAnchor),
            hv.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            hv.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            hv.bottomAnchor.constraint(equalTo: self.view.bottomAnchor)
        ])
        hostingView = hv

        log.info("configureSwiftUIView done")
    }
}
