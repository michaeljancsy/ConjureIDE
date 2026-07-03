//
//  AudioUnitViewController.swift
//  ConjureDSPExtension
//
//  Created by Michael Jancsy on 2/25/26.
//

import Combine
import CoreAudioKit
import os
import Sentry
import SwiftUI

private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSPExtension", category: "AudioUnitViewController")

extension Notification.Name {
    /// Posted via DistributedNotificationCenter when the extension stages a
    /// pending AU export, so the host app can pick it up from Group Containers.
    static let conjureDSPPendingExport = Notification.Name("com.MichaelJancsy.ConjureDSP.pendingExport")
}

// MARK: - SafeHostingView

/// NSHostingView subclass that guards against the macOS 14+ ViewBridge bug
/// where `NSViewServiceMarshal` fails to render a second AUv3 ViewController
/// in the same extension process. When the old VC's hosting view is removed
/// from its window, `viewDidMoveToWindow()` with `window == nil` would tear
/// down SwiftUI's rendering pipeline. Skipping `super` in that case prevents
/// interference with the new VC's view.
private class SafeHostingView<Content: View>: NSHostingView<Content> {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

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

    // MARK: - New Preset Templates

    // swiftlint:disable indentation_width
    static let newPythonTemplate = """
import numpy as np

PARAMS = {
    "gain": {"min": -24.0, "max": 12.0, "unit": "dB", "default": 0.0},
}


def process(ctx):
    \"""
    Process audio buffers.

    Called once per audio render callback. Whole-array numpy ops broadcast
    across channels and frames in one SIMD pass — prefer them over per-channel
    Python loops.

    `ctx` exposes:
        ctx.inputs       2D numpy.float32 array, shape (channels, frame_count)
        ctx.outputs      2D numpy.float32 array, shape (channels, frame_count)
        ctx.frame_count  number of valid samples this callback (arrays are
                         already sliced to this length — no extra [:n] needed)
        ctx.sample_rate  current sample rate in Hz (e.g. 44100.0)
        ctx.params       read-only view; ctx.params["gain"] or ctx.params.gain
        ctx.transport    read-only mapping (bpm, beat, is_playing, ...)
        ctx.telemetry    write per-block scalar readouts the UI can show
        ctx.state        read-only mapping over the bundle's STATE channel
        ctx.sidechain    2D numpy.float32 array, same shape as inputs; zero-
                         filled when no sidechain bus is connected
    \"""
    gain_db = ctx.params["gain"]
    gain = 10.0 ** (gain_db / 20.0)

    np.multiply(ctx.inputs, gain, out=ctx.outputs)
"""

    /// Default Rust preset template, loaded from the extension bundle's
    /// `Resources/process.rs` so there's one source of truth for the
    /// shape new bundles seed with. The file is shipped via the
    /// extension target's PBXFileSystemSynchronizedRootGroup; the
    /// `DocsDriftGuardTests.processRsIsShippedInBuiltExtensionResources`
    /// logic test fails CI if it ever stops being bundled.
    ///
    /// The 100-byte length floor guards against a half-shipped resource
    /// (truncated download, build script error) silently seeding new
    /// bundles with a few bytes of nothing. `process.rs` is ~700 bytes;
    /// anything under 100 means the resource lookup gave us garbage.
    static let newRustTemplate: String = {
        let bundle = Bundle(for: AudioUnitViewController.self)
        if let url = bundle.url(forResource: "process", withExtension: "rs"),
           let contents = try? String(contentsOf: url, encoding: .utf8),
           contents.count > 100 {
            return contents
        }
        log.error("""
            Resources/process.rs missing or unexpectedly short in bundle at \
            \(bundle.bundlePath, privacy: .public); falling back to embedded template. \
            New Rust bundles will be seeded with the minimal fallback below.
            """)
        return AudioUnitViewController.embeddedRustFallback
    }()

    /// Minimal compilable fallback used only when the bundle resource
    /// load above fails. Kept tiny on purpose — the real template lives
    /// in `Resources/process.rs`; touching this fallback should be rare.
    private static let embeddedRustFallback = """
use conjuredsp::*;

params! {
    GAIN = db().min(-24.0).max(12.0).default(0.0),
}

process! { ctx =>
    let gain = db_to_gain(ctx.param(GAIN) as f64) as f32;
    for c in 0..ctx.channels() {
        for i in 0..ctx.frames() {
            ctx.set_output(c, i, ctx.input(c, i) * gain);
        }
    }
}
"""
    // swiftlint:enable indentation_width

    private static var sentryStarted = false

    var audioUnit: AUAudioUnit? {
        didSet {
            log.info("audioUnit didSet, isViewLoaded=\(self.isViewLoaded, privacy: .public)")
        }
    }

    private var hostingView: SafeHostingView<ConjureDSPExtensionMainView>?
    private var captureManager: AudioCaptureManager?
    private var processProfiler: ProcessProfiler?
    private var memoryMonitor: MemoryMonitor?
    private var parameterState: ParameterState?
    private var gitHubService: GitHubService?
    private var gitCoordinator: PresetGitCoordinator?
    private var terminalServer: TerminalServer?
    /// Unique identifier for this AU instance — used for per-instance terminal discovery.
    private let instanceID = UUID().uuidString
    private var paramNamesCancellable: AnyCancellable?
    private var paramMetadataCancellable: AnyCancellable?
    private var renderResourcesCancellable: AnyCancellable?
    private var manifestDriftCancellable: AnyCancellable?
    private var runtimePollTimer: Timer?

    /// App Group container URL — uses direct path construction to avoid
    /// TCC "access data from other apps" prompts on macOS 26.
    private var appGroupContainerURL: URL {
        AppGroupContainer.url
    }

	deinit {
        runtimePollTimer?.invalidate()
        captureManager?.setConsumer(id: "spectrogram", active: false)
        // Custom-UI audio consumer is owned by CustomUIWebView.Coordinator
        // and deregistered in dismantleNSView — the ID is per-coordinator
        // (`"customUI-<hash>"`), so any call from here wouldn't match.
        processProfiler?.stop()
        memoryMonitor?.stop()
        terminalServer?.stop()
        terminalServer = nil
        log.info("deinit — terminal server stopped")
	}

    /// Provide a fresh NSView container each time the system creates this VC.
    /// This forces the ViewBridge to work with a new view hierarchy, working
    /// around the NSViewServiceMarshal bug in macOS 14+ where a second VC
    /// in the same extension process fails to render.
    public override var preferredMinimumSize: NSSize {
        NSSize(width: 600, height: 300)
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
        SentryHelper.breadcrumb("AU viewDidLoad", category: "au.lifecycle")
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        if self.view.frame.size != self.preferredContentSize {
            self.preferredContentSize = self.view.frame.size
        }
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
            // Seed `pm.currentPreset` so the picker reflects what's
            // actually loaded in the kernel. Order of preference:
            //   1. Whatever Logic asserted via `AUAudioUnit.currentPreset`
            //      during AU init (this is the common path — Logic
            //      auto-picks `factoryPresets[0]` on instantiate).
            //   2. The AU's own `defaultPresetResource` (stereowidth).
            // Without (1), the picker gets seeded from `defaultPresetResource`
            // even when Logic has already loaded a different preset, and
            // the picker silently lies about what's running.
            if pm.currentPreset == nil {
                let auCurrent = au.currentPreset
                let matchedFromAU: Preset? = auCurrent.flatMap { aup in
                    pm.presets.first { $0.factoryPresetNumber == aup.number }
                }
                let fallback = pm.presets.first { preset in
                    guard case .factory(let name) = preset.source else { return false }
                    return name == ConjureDSPExtensionAudioUnit.defaultPresetResource
                }
                if let chosen = matchedFromAU ?? fallback {
                    pm.setCurrentPreset(chosen, source: restored)
                }
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
            initialScript = ""
            initialLanguage = .python
            initialBenchmark = nil

            // Python runtime not provisioned yet (clean install race).
            // Poll until ConjureDSPTerminal finishes provisioning, then load the default preset.
            self.startRuntimePolling(au: au, pm: pm)
        }

        if captureManager == nil {
            captureManager = AudioCaptureManager()
        }
        let capture = captureManager!
        capture.kernel = au.kernelReference
        capture.hostView = self.view
        let initialSR = au.outputBusses[0].format.sampleRate
        capture.sampleRate = initialSR > 0 ? initialSR : 44100.0

        // Owned by the AU (a `let` property set at AU init) so the audio
        // thread reads a stable strong reference, not a weak that the main
        // thread could be writing to. Survives VC churn for free.
        let transport: TransportPushManager = (au as? ConjureDSPExtensionAudioUnit)?.transportPushManager
            ?? TransportPushManager()

        if processProfiler == nil {
            processProfiler = ProcessProfiler()
        }
        let profiler = processProfiler!
        profiler.kernel = au.kernelReference
        profiler.sampleRate = initialSR > 0 ? initialSR : 44100.0
        profiler.maxFrames = au.maximumFramesToRender > 0 ? au.maximumFramesToRender : 512
        profiler.start()
        if let conjureAU = au as? ConjureDSPExtensionAudioUnit {
            renderResourcesCancellable = conjureAU.renderConfigurationChanged
                .receive(on: RunLoop.main)
                .sink { [weak profiler, weak capture] maxFrames, sampleRate in
                    profiler?.maxFrames = maxFrames
                    profiler?.sampleRate = sampleRate
                    capture?.sampleRate = sampleRate
                }
        }

        if memoryMonitor == nil {
            memoryMonitor = MemoryMonitor()
        }
        let memMon = memoryMonitor!
        memMon.kernel = au.kernelReference
        memMon.start()

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
            // No `.receive(on: DispatchQueue.main)` here — the sink must
            // run SYNCHRONOUSLY from `paramMetadataDidChange.send(...)`
            // so that `ParameterState.paramMetadata` is up to date by
            // the time the closure returns. Custom-UI webviews that
            // race to post 'ready' during a preset switch would
            // otherwise see the previous preset's metadata in
            // `makeInitPayload`. All senders are on main; the
            // subscription assertion below catches any future caller
            // that isn't.
            paramMetadataCancellable = au.paramMetadataDidChange
                .sink { [weak ps, weak au] metadata in
                    MainActor.assertIsolated("paramMetadataDidChange must be sent on main")
                    ps?.paramMetadata = metadata
                    if let tree = au?.parameterTree {
                        ps?.attach(to: tree)
                    }
                }
        }

        if gitHubService == nil {
            gitHubService = GitHubService()
        }
        let gh = gitHubService!

        // Presets live inside a git repo under Presets/. The coordinator runs
        // `initIfNeeded` on first launch, then commits on save/delete/rename.
        if gitCoordinator == nil {
            gitCoordinator = PresetGitCoordinator(
                presetsURL: pm.presetsURL,
                appGroupURL: appGroupContainerURL,
                tokenProvider: { [weak gh] in gh?.token }
            )
        }
        let gc = gitCoordinator!
        Task { await gc.initIfNeeded() }

        // Subscribe to the AU's auto-sync signal: when a load detects
        // drift between `manifest.params` and the kernel's freshly-
        // extracted metadata, the AU rewrites the manifest on disk and
        // emits the bundle root URL here. We route that through
        // `gc.recordSave` so the auto-rewrite shows up in the preset
        // repo's git log alongside every other preset mutation.
        //
        // `.receive(on: DispatchQueue.main)` pushes the sink to the
        // back of the run loop's queue. That matters in the save flow
        // path: `reloadScript(persistManifest: true)` emits this
        // Publisher synchronously, and the save closure then
        // immediately enqueues its OWN `gc.recordSave(message: "Update
        // <name>")`. With async delivery, the save's commit task
        // arrives at `gc` first, captures BOTH the source diff and
        // the manifest sync diff in one commit with the user's chosen
        // message, and the sync's commit becomes a no-op (nothing
        // left in the working tree). On non-save paths (e.g.
        // `selectPreset` against a stale bundle), no save is in
        // flight, so the sync's commit fires and captures the
        // manifest rewrite by itself.
        manifestDriftCancellable = au.manifestDriftCorrected
            .receive(on: DispatchQueue.main)
            .sink { [weak gc] bundleURL in
                guard let gc else { return }
                Task { @MainActor in
                    _ = await gc.recordSave(
                        paths: [bundleURL],
                        message: "Sync manifest.params from kernel"
                    )
                }
            }

        // Run: detect language, compile if needed, load into kernel + benchmark
        let onRun: (String) async -> ScriptSaveResult = { [weak au] source in
            guard let au else {
                return ScriptSaveResult(success: false, error: "Audio unit not available", processTimeMs: nil, budgetMs: nil)
            }
            // Mute output across the load window so a new backend with
            // different default parameter values doesn't click against the
            // old backend's continuous DSP state.
            au.beginPresetTransition()
            defer { au.endPresetTransition() }
            // `persistManifest: true` is the Rust save path's lifeline:
            // the synchronous Rust save closure can't fire the sync
            // (no kernel compile happens there), so the next Run is
            // where the compile + sync chain completes. Python iterates
            // through the same path and gets the same auto-correction
            // when the editor's params drift from disk.
            let result = await au.compileAndRun(source: source, persistManifest: true)
            Analytics.track(.scriptRun, properties: [
                "language": ScriptLanguage.detect(from: source).rawValue,
                "success": result.success,
            ])
            return ScriptSaveResult(success: result.success, error: result.error, warning: result.warning, processTimeMs: result.processTimeMs, budgetMs: result.budgetMs)
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

        // Save: overwrite the current user preset, hot-reload, then commit.
        // `userCommitMessage` comes from the SaveMessagePopover (alwaysPrompt mode)
        // or is nil (alwaysTimestamp, or empty popover field — coordinator substitutes default).
        // Commit fires only when the reload/compile succeeded.
        let onSavePreset: (_ source: String, _ language: ScriptLanguage, _ userCommitMessage: String?) -> ScriptSaveResult = { [weak au, weak pm, weak gc] source, language, userCommitMessage in
            guard let au, let pm else {
                return ScriptSaveResult(success: false, error: "Audio unit not available", processTimeMs: nil, budgetMs: nil)
            }
            guard let current = pm.currentPreset, !current.isFactory else {
                return ScriptSaveResult(success: false, error: "No user preset selected", processTimeMs: nil, budgetMs: nil)
            }
            do {
                let saved: Preset = try pm.savePreset(name: current.name, source: source, language: language)
                Analytics.track(.presetSave, properties: [
                    "preset_name": current.name,
                    "is_new": false,
                    "language": language.rawValue,
                ])
                Analytics.flush()

                let commitMessage = userCommitMessage ?? gc?.defaultMessage(for: .update(name: saved.name))
                let commitURL = saved.fileURL
                let doCommit: (Bool) -> Void = { [weak pm] success in
                    guard success, let gc, let fileURL = commitURL, let message = commitMessage else { return }
                    Task { @MainActor in
                        let result = await gc.recordSave(paths: [fileURL], message: message)
                        // Clear the dirty set only on commit success —
                        // otherwise the Save button needs to stay enabled
                        // so the user can retry.
                        if case .success = result {
                            pm?.clearDirtyFiles()
                        }
                    }
                }

                switch language {
                case .python:
                    au.beginPresetTransition()
                    defer { au.endPresetTransition() }
                    // `persistManifest: true` so the manifest's
                    // `params` block stays in sync with the saved
                    // source. The Publisher → AVC sink → recordSave
                    // path coordinates with `doCommit` below; see the
                    // `manifestDriftCancellable` doc comment for why
                    // both can fire without producing two commits.
                    let result = au.reloadScript(source: source, persistManifest: true)
                    pm.setCurrentPreset(saved, source: source)
                    doCommit(result.success)
                    return ScriptSaveResult(success: result.success, error: result.error, processTimeMs: result.processTimeMs, budgetMs: result.budgetMs)
                case .rust:
                    // No reloadScript here — Rust compile is async and
                    // happens when the user clicks Run. The eventual
                    // `compileAndRun(persistManifest: true)` call from
                    // `onRun` is what propagates the manifest sync.
                    au.currentScriptLanguage = .rust
                    pm.setCurrentPreset(saved, source: source)
                    doCommit(true)
                    return ScriptSaveResult(success: true, error: nil, processTimeMs: nil, budgetMs: nil)
                }
            } catch {
                return ScriptSaveResult(success: false, error: error.localizedDescription, processTimeMs: nil, budgetMs: nil)
            }
        }

        // Save As: create a new user preset, hot-reload, then commit.
        let onSaveAsPreset: (_ name: String, _ source: String, _ language: ScriptLanguage, _ userCommitMessage: String?, _ includeCustomUI: Bool) -> ScriptSaveResult = { [weak au, weak pm, weak gc] name, source, language, userCommitMessage, includeCustomUI in
            guard let au, let pm else {
                return ScriptSaveResult(success: false, error: "Audio unit not available", processTimeMs: nil, budgetMs: nil)
            }
            do {
                // Save As forks the currently-loaded bundle when there is
                // one, preserving the source preset's `ui/`, manifest.params,
                // and any author assets. Falls back to a fresh bundle (with
                // optional starter UI scaffold) when nothing is loaded — the
                // scratchpad / post-New case.
                let saved: Preset = try pm.savePreset(
                    name: name,
                    source: source,
                    language: language,
                    scaffoldUI: includeCustomUI,
                    duplicateFrom: pm.currentBundle
                )
                Analytics.track(.presetSave, properties: [
                    "preset_name": name,
                    "is_new": true,
                    "language": language.rawValue,
                ])
                Analytics.flush()

                let commitMessage = userCommitMessage ?? gc?.defaultMessage(for: .add(name: saved.name))
                let commitURL = saved.fileURL
                let doCommit: (Bool) -> Void = { success in
                    guard success, let gc, let fileURL = commitURL, let message = commitMessage else { return }
                    Task { _ = await gc.recordSave(paths: [fileURL], message: message) }
                }

                switch language {
                case .python:
                    au.beginPresetTransition()
                    defer { au.endPresetTransition() }
                    // Same `persistManifest: true` rationale as the
                    // `onSavePreset` Python branch.
                    let result = au.reloadScript(source: source, persistManifest: true)
                    pm.setCurrentPreset(saved, source: source)
                    doCommit(result.success)
                    return ScriptSaveResult(success: result.success, error: result.error, processTimeMs: result.processTimeMs, budgetMs: result.budgetMs)
                case .rust:
                    // Save-As of a Rust preset: same as `onSavePreset` —
                    // no synchronous compile here, the manifest sync
                    // happens on the next Run via `compileAndRun`'s
                    // persistManifest plumbing.
                    au.currentScriptLanguage = .rust
                    pm.setCurrentPreset(saved, source: source)
                    doCommit(true)
                    return ScriptSaveResult(success: true, error: nil, processTimeMs: nil, budgetMs: nil)
                }
            } catch {
                return ScriptSaveResult(success: false, error: error.localizedDescription, processTimeMs: nil, budgetMs: nil)
            }
        }

        // Delete: remove current user preset, then commit the removal.
        // Per-preset delete used by the preset browser's right-click. Mirrors
        // `onDeletePreset` but takes the target as an argument so it works
        // for any user bundle, not just the current one (e.g. deleting a
        // broken bundle without first selecting it).
        let onDeleteUserPreset: (Preset) -> Void = { [weak pm, weak gc] preset in
            guard let pm, !preset.isFactory else { return }
            guard let fileURL = preset.fileURL else { return }
            let name = preset.name
            do {
                try pm.deleteUserPreset(preset)
                if let gc {
                    let message = gc.defaultMessage(for: .delete(name: name))
                    Task { _ = await gc.recordDelete(path: fileURL, message: message) }
                }
            } catch {
                log.error("Delete failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        let onDeletePreset: () -> Void = { [weak pm] in
            guard let pm, let current = pm.currentPreset, !current.isFactory else { return }
            onDeleteUserPreset(current)
        }

        // Open a broken bundle for repair — `setBrokenPresetForRepair`
        // populates `currentBundle` via `PresetBundle.inspect` and leaves
        // `loadedSource` nil. Audio stays passthrough until the user fixes
        // the manifest and re-saves.
        let onSelectBrokenBundle: (Preset) -> Void = { [weak pm] preset in
            pm?.setBrokenPresetForRepair(preset)
        }

        // Rename: rename current user preset, then commit the move.
        let onRenamePreset: (String) -> String? = { [weak pm, weak gc] newName in
            guard let pm, let current = pm.currentPreset, !current.isFactory else {
                return "No preset selected"
            }
            let oldName = current.name
            let oldURL = current.fileURL
            do {
                let renamed = try pm.renamePreset(current, to: newName)
                if let gc, let oldURL, let newURL = renamed.fileURL {
                    let message = gc.defaultMessage(for: .rename(old: oldName, new: renamed.name))
                    Task { _ = await gc.recordRename(oldPath: oldURL, newPath: newURL, message: message) }
                }
                return nil
            } catch {
                return error.localizedDescription
            }
        }

        // New Preset: writes a fresh .cdp bundle to disk with the chosen
        // language + UI type, commits via the git coordinator, then switches
        // the current preset to it. No scratchpad — every preset exists on
        // disk from the moment of creation, so Cmd+S is always a commit.
        // Returns nil on success, or an error string for the popover to
        // display inline (disk write failed, git refused the commit, etc.).
        let extensionBundle = Bundle(for: type(of: self))
        let onNew: (_ name: String, _ language: ScriptLanguage, _ includeCustomUI: Bool) -> String? = { [weak au, weak pm, weak gc] name, language, includeCustomUI in
            guard let au, let pm else {
                return "Audio unit not available"
            }
            let source = language == .rust ? Self.newRustTemplate : Self.newPythonTemplate
            do {
                let saved: Preset = try pm.savePreset(
                    name: name,
                    source: source,
                    language: language,
                    scaffoldUI: includeCustomUI
                )
                Analytics.track(.presetSave, properties: [
                    "preset_name": name,
                    "is_new": true,
                    "language": language.rawValue,
                    "from": "new_preset",
                    "include_custom_ui": includeCustomUI,
                ])
                Analytics.flush()

                // Always use the default "Add <name>" message — the New
                // Preset dialog deliberately doesn't ask for a commit
                // message. Users control commit text via Cmd+S after the
                // bundle exists; the first commit is routine.
                let commitMessage = gc?.defaultMessage(for: .add(name: saved.name))
                let commitURL = saved.fileURL
                let doCommit: (Bool) -> Void = { success in
                    guard success, let gc, let fileURL = commitURL, let message = commitMessage else { return }
                    Task { _ = await gc.recordSave(paths: [fileURL], message: message) }
                }

                // Hold the audio output muted across param-tree mutation +
                // kernel reload. Same reason as `selectPreset`: the OLD
                // backend keeps rendering with the NEW preset's parameter
                // values until the new backend is staged and the swap
                // envelope completes.
                au.beginPresetTransition()
                defer { au.endPresetTransition() }

                // CRITICAL ORDERING (mirrors selectPreset): apply
                // manifest params or reset to a generic tree BEFORE
                // setCurrentPreset triggers the SwiftUI update that
                // recreates CustomUIWebView. Otherwise the new webview's
                // first _initSliders carries the previous preset's
                // metadata (e.g. compressor threshold/ratio/attack on a
                // brand-new template) until the next compile lands.
                if let bundle = pm.loadBundle(for: saved),
                   let meta = bundle.manifest.resolvedParamMetadata() {
                    au.applyManifestParams(meta)
                } else {
                    au.resetParameterTreeToGeneric()
                }

                switch language {
                case .python:
                    // `persistManifest: true` so the New-Preset
                    // template's `PARAMS` lands in the manifest's
                    // `params` block on first save — the bundle starts
                    // life with metadata authors can immediately bind
                    // `<cdp-slider param="…">` against without an
                    // intermediate Run.
                    let result = au.reloadScript(source: source, persistManifest: true)
                    pm.setCurrentPreset(saved, source: source)
                    // Propagate the new source to the Monaco editor.
                    // Without this, the editor stays on the previous
                    // preset's code while the custom UI renders the
                    // newly-compiled metadata — the "script says width,
                    // UI says Gain" mismatch.
                    au.scriptSourceDidChange.send(
                        ConjureDSPExtensionAudioUnit.ScriptSourceChange(source: source)
                    )
                    doCommit(result.success)
                    if !result.success {
                        return result.error ?? "Failed to load new preset"
                    }
                    return nil
                case .rust:
                    // Don't compile on create — user hits Run when ready.
                    au.currentScriptLanguage = .rust
                    pm.setCurrentPreset(saved, source: source)
                    au.scriptSourceDidChange.send(
                        ConjureDSPExtensionAudioUnit.ScriptSourceChange(source: source)
                    )
                    doCommit(true)
                    return nil
                }
            } catch {
                return error.localizedDescription
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
        let appGroupURL = self.appGroupContainerURL
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
            let exportDir = appGroupURL.appendingPathComponent("PendingExports")
            try? FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)

            // When the active preset is a bundle with a present custom UI,
            // tell the exporter to carry it forward. `hasCustomUI` already
            // verifies the manifest declares a ui block AND `ui/index.html`
            // exists on disk, so there's no need to stat again here.
            let customUIPayload: ExportManager.CustomUIPayload? = {
                guard let bundle = au.presetManager.currentBundle,
                      bundle.hasCustomUI,
                      let uiDir = bundle.uiDirectoryURL else { return nil }
                let uiMeta = bundle.manifest.ui
                // `uiEntryHTMLPath` is bundle-root-relative ("ui/index.html").
                // The exporter copies the bundle's `ui/` directory verbatim
                // into `.appex/Contents/Resources/ui/`, so we only need the
                // path relative to that directory — strip the leading "ui/".
                let entryHTML: String = {
                    let p = bundle.manifest.uiEntryHTMLPath
                    return p.hasPrefix("ui/") ? String(p.dropFirst(3)) : p
                }()
                return ExportManager.CustomUIPayload(
                    directory: uiDir,
                    entryHTML: entryHTML,
                    width: uiMeta?.width,
                    height: uiMeta?.height,
                    fps: bundle.manifest.resolvedFPS,
                    audioFrames: bundle.manifest.audioFramesEnabled
                )
            }()

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
                    paramMetadata: au.currentParamMetadata,
                    latencySamples: au._latencySamples,
                    customUI: customUIPayload
                )
                log.info("Staged preset '\(name, privacy: .public)' to App Group at \(appURL.path, privacy: .public)")

                // Notify the host app so it can pick up the export without
                // polling Group Containers (which triggers TCC prompts).
                DistributedNotificationCenter.default().postNotificationName(
                    .conjureDSPPendingExport,
                    object: nil,
                    deliverImmediately: true
                )

                Analytics.track(.export, properties: [
                    "name": name,
                    "language": language.rawValue,
                    "success": true,
                ])
                Analytics.flush()
                return .success("Exported \"\(name)\"! Installing...")
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

        // Surfaces load failures from non-SwiftUI-driven paths (DAW
        // preset menu, extension boot, NAM-retry) so the SwiftUI status
        // bar shows the same red error it would for Run / in-plugin
        // browser failures.
        let scriptLoadFailurePublisher = au.scriptLoadFailure
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()

        // PR #4: Runtime errors from `process()` raises. Fires when the
        // kernel's `last_error` transitions (None → Some, Some → None,
        // Some(x) → Some(y)). The main view subscribes to push a Monaco
        // marker at the offending line and show a persistent banner that
        // stays visible across all bundle files (so the user notices the
        // error even when editing `ui/index.html`).
        let runtimeErrorPublisher = au.runtimeErrorChanged
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()

        let buildID = extensionBundle.infoDictionary?["BuildID"] as? Int ?? 0

        // Bundle-private STATE channel coordinator — owned by the AU,
        // passed through to the SwiftUI tree so CustomUIWebView can wire
        // the JS bridge `state.set`/`state.reset` round-trip.
        let stateMgr = au.presetStateManager

        let content = ConjureDSPExtensionMainView(
            buildID: buildID,
            defaultScriptSource: initialScript,
            defaultLanguage: initialLanguage,
            extensionBundle: extensionBundle,
            scriptSourcePublisher: scriptPublisher,
            scriptLoadFailurePublisher: scriptLoadFailurePublisher,
            runtimeErrorPublisher: runtimeErrorPublisher,
            presetManager: pm,
            captureManager: capture,
            transportManager: transport,
            processProfiler: profiler,
            memoryMonitor: memMon,
            parameterState: ps,
            stateManager: stateMgr,
            gitHubService: gh,
            gitCoordinator: gc,
            onRun: onRun,
            onSelectPreset: onSelectPreset,
            onSavePreset: onSavePreset,
            onSaveAsPreset: onSaveAsPreset,
            onDeletePreset: onDeletePreset,
            onDeleteUserPreset: onDeleteUserPreset,
            onSelectBrokenBundle: onSelectBrokenBundle,
            onRenamePreset: onRenamePreset,
            onNew: onNew,
            onExport: onExport,
            defaultBenchmark: initialBenchmark,
            appGroupContainerURL: appGroupContainerURL,
            instanceID: instanceID,
            isBypassed: { [weak au] in au?.shouldBypassEffect ?? false },
            setBypass: { [weak au] bypass in au?.shouldBypassEffect = bypass }
        )
        let hv = SafeHostingView(rootView: content)
        hv.sizingOptions = []
        hv.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(hv)
        NSLayoutConstraint.activate([
            hv.topAnchor.constraint(equalTo: self.view.topAnchor),
            hv.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            hv.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            hv.bottomAnchor.constraint(equalTo: self.view.bottomAnchor)
        ])
        hostingView = hv

        // Start terminal/MCP infrastructure — direct access to the real AU, no proxy
        if terminalServer == nil {
            let ts = TerminalServer(instanceID: instanceID, appGroupContainerURL: appGroupContainerURL)
            ts.mcpServer.toolProvider = au  // Set before start so first connection sees it
            ts.start()
            terminalServer = ts
            log.info("Terminal server started with direct AU access (instance \(self.instanceID, privacy: .public))")
        }

        log.info("configureSwiftUIView done")
    }

    // MARK: - Runtime Provisioning Retry

    /// Poll for the Python runtime to appear (provisioned by ConjureDSPTerminal),
    /// then load the default preset and update the UI. Stops after success or 30s.
    private func startRuntimePolling(au: ConjureDSPExtensionAudioUnit, pm: PresetManager) {
        runtimePollTimer?.invalidate()
        var attempts = 0
        let maxAttempts = 30  // 30 x 1s = 30s max wait
        runtimePollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self, weak au, weak pm] timer in
            guard let self, let au, let pm else {
                timer.invalidate()
                return
            }
            attempts += 1
            if au.retryLoadDefaultPreset() {
                timer.invalidate()
                self.runtimePollTimer = nil
                // If the host had already asserted `currentPreset` before
                // Python was ready, retryLoadDefaultPreset took the
                // "replay" path and the AU's setter is already syncing
                // `pm.currentPreset` via its own @MainActor Task. Don't
                // touch pm here — racing the setter would briefly flip
                // the picker to stereowidth before settling on the
                // host's actual choice.
                if au.currentPreset != nil {
                    log.info("Python runtime found after \(attempts)s — host's currentPreset replayed")
                } else if let defaultPreset = pm.presets.first(where: { preset in
                    guard case .factory(let name) = preset.source else { return false }
                    return name == ConjureDSPExtensionAudioUnit.defaultPresetResource
                }) {
                    log.info("Python runtime found after \(attempts)s — bundled default loaded")
                    pm.setCurrentPreset(defaultPreset, source: au.scriptSource ?? "")
                }
            } else if attempts >= maxAttempts {
                timer.invalidate()
                self.runtimePollTimer = nil
                log.error("Python runtime not provisioned after \(maxAttempts)s — giving up")
            }
        }
    }
}
