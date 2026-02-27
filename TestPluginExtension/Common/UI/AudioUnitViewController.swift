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

	deinit {
        log.info("deinit called")
	}

    /// Provide a fresh NSView container each time the system creates this VC.
    /// This forces the ViewBridge to work with a new view hierarchy, working
    /// around the NSViewServiceMarshal bug in macOS 14+ where a second VC
    /// in the same extension process fails to render.
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

        let defaultScript: String
        if let scriptURL = Bundle(for: type(of: self)).url(forResource: "process", withExtension: "py"),
           let source = try? String(contentsOf: scriptURL, encoding: .utf8) {
            defaultScript = source
        } else {
            defaultScript = "# process.py not found in bundle\n"
        }

        let onSaveScript: (String) -> (Bool, String?) = { [weak audioUnit] source in
            guard let au = audioUnit as? TestPluginExtensionAudioUnit else {
                return (false, "Audio unit not available")
            }
            let result = au.reloadScript(source: source)
            return (result.success, result.error)
        }

        let content = TestPluginExtensionMainView(
            defaultScriptSource: defaultScript,
            onSaveScript: onSaveScript
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
