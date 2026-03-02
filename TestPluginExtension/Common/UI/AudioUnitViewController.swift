//
//  AudioUnitViewController.swift
//  TestPluginExtension
//
//  Created by Michael Jancsy on 2/25/26.
//

import Combine
import CoreAudioKit
import os
import SwiftUI

private let log = Logger(subsystem: "com.MichaelJancsy.TestPluginExtension", category: "AudioUnitViewController")

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
    var audioUnit: AUAudioUnit? {
        didSet {
            log.info("audioUnit didSet, isViewLoaded=\(self.isViewLoaded, privacy: .public)")
        }
    }

    private var hostingView: SafeHostingView<TestPluginExtensionMainView>?
    private var aiService: AIService?

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
        NSSize(width: 1400, height: 800)
    }

    public override func loadView() {
        let defaultSize = NSSize(width: 600, height: 500)
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

			audioUnit = try TestPluginExtensionAudioUnit(componentDescription: componentDescription, options: [])

			guard let audioUnit = self.audioUnit as? TestPluginExtensionAudioUnit else {
				log.error("Unable to create TestPluginExtensionAudioUnit")
				return audioUnit!
			}

			return audioUnit
		}
	}

    private func configureSwiftUIView(audioUnit: AUAudioUnit) {
        log.info("configureSwiftUIView called")

        hostingView?.removeFromSuperview()

        guard let au = audioUnit as? TestPluginExtensionAudioUnit else {
            log.error("audioUnit is not TestPluginExtensionAudioUnit")
            return
        }

        // Use restored script from fullState if available, otherwise fall back to bundled default
        let initialScript: String
        if let restored = au.scriptSource {
            initialScript = restored
        } else if let scriptURL = Bundle(for: type(of: self)).url(forResource: "process", withExtension: "py"),
                  let source = try? String(contentsOf: scriptURL, encoding: .utf8) {
            initialScript = source
        } else {
            initialScript = "# process.py not found in bundle\n"
        }

        let pm = au.presetManager

        if aiService == nil {
            aiService = AIService()
        }
        let ai = aiService!

        // Run: hot-reload script into kernel + benchmark
        let onRun: (String) -> ScriptSaveResult = { [weak au] source in
            guard let au else {
                return ScriptSaveResult(success: false, error: "Audio unit not available", processTimeMs: nil, budgetMs: nil)
            }
            let result = au.reloadScript(source: source)
            return ScriptSaveResult(success: result.success, error: result.error, processTimeMs: result.processTimeMs, budgetMs: result.budgetMs)
        }

        // Select preset: load into kernel + update preset manager
        let onSelectPreset: (Preset) -> ScriptSaveResult = { [weak au] preset in
            guard let au else {
                return ScriptSaveResult(success: false, error: "Audio unit not available", processTimeMs: nil, budgetMs: nil)
            }
            return au.selectPreset(preset)
        }

        // Save: overwrite current user preset + hot-reload
        let onSavePreset: (String) -> ScriptSaveResult = { [weak au, weak pm] source in
            guard let au, let pm else {
                return ScriptSaveResult(success: false, error: "Audio unit not available", processTimeMs: nil, budgetMs: nil)
            }
            guard let current = pm.currentPreset, !current.isFactory else {
                return ScriptSaveResult(success: false, error: "No user preset selected", processTimeMs: nil, budgetMs: nil)
            }
            do {
                let saved = try pm.saveUserPreset(name: current.name, source: source)
                let result = au.reloadScript(source: source)
                pm.setCurrentPreset(saved, source: source)
                return ScriptSaveResult(success: result.success, error: result.error, processTimeMs: result.processTimeMs, budgetMs: result.budgetMs)
            } catch {
                return ScriptSaveResult(success: false, error: error.localizedDescription, processTimeMs: nil, budgetMs: nil)
            }
        }

        // Save As: create new user preset + hot-reload
        let onSaveAsPreset: (String, String) -> ScriptSaveResult = { [weak au, weak pm] name, source in
            guard let au, let pm else {
                return ScriptSaveResult(success: false, error: "Audio unit not available", processTimeMs: nil, budgetMs: nil)
            }
            do {
                let saved = try pm.saveUserPreset(name: name, source: source)
                let result = au.reloadScript(source: source)
                pm.setCurrentPreset(saved, source: source)
                return ScriptSaveResult(success: result.success, error: result.error, processTimeMs: result.processTimeMs, budgetMs: result.budgetMs)
            } catch {
                return ScriptSaveResult(success: false, error: error.localizedDescription, processTimeMs: nil, budgetMs: nil)
            }
        }

        // Delete: remove current user preset
        let onDeletePreset: () -> Void = { [weak pm] in
            guard let pm, let current = pm.currentPreset, !current.isFactory else { return }
            try? pm.deleteUserPreset(current)
        }

        // New: reset to default passthrough script
        let extensionBundle = Bundle(for: type(of: self))
        let onNew: () -> ScriptSaveResult = { [weak au, weak pm] in
            guard let au, let pm else {
                return ScriptSaveResult(success: false, error: "Audio unit not available", processTimeMs: nil, budgetMs: nil)
            }
            guard let entry = FactoryPresetRegistry.entries.first,
                  let url = extensionBundle.url(forResource: entry.resourceName, withExtension: "py"),
                  let source = try? String(contentsOf: url, encoding: .utf8) else {
                return ScriptSaveResult(success: false, error: "Default script not found", processTimeMs: nil, budgetMs: nil)
            }
            let result = au.reloadScript(source: source)
            pm.setCurrentPreset(nil, source: source)
            au.scriptSourceDidChange.send(source)
            return ScriptSaveResult(success: result.success, error: result.error, processTimeMs: result.processTimeMs, budgetMs: result.budgetMs)
        }

        let scriptPublisher = au.scriptSourceDidChange
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()

        let buildID = extensionBundle.infoDictionary?["BuildID"] as? Int ?? 0

        let content = TestPluginExtensionMainView(
            buildID: buildID,
            defaultScriptSource: initialScript,
            scriptSourcePublisher: scriptPublisher,
            presetManager: pm,
            aiService: ai,
            onRun: onRun,
            onSelectPreset: onSelectPreset,
            onSavePreset: onSavePreset,
            onSaveAsPreset: onSaveAsPreset,
            onDeletePreset: onDeletePreset,
            onNew: onNew
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
