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

@MainActor
public class AudioUnitViewController: AUViewController, AUAudioUnitFactory {
    var audioUnit: AUAudioUnit? {
        didSet {
            log.info("audioUnit didSet, isViewLoaded=\(self.isViewLoaded, privacy: .public)")
            guard let audioUnit, isViewLoaded else { return }
            if hostingView == nil {
                configureSwiftUIView(audioUnit: audioUnit)
            }
        }
    }

    /// NSHostingView instead of NSHostingController: avoids child-VC lifecycle
    /// issues where NSHostingController stops rendering after viewDidDisappear
    /// and never resumes if the host doesn't call viewWillAppear on reopen.
    private var hostingView: NSHostingView<TestPluginExtensionMainView>?

	deinit {
        log.info("deinit called")
	}

    public override func viewDidLoad() {
        super.viewDidLoad()
        log.info("viewDidLoad called, audioUnit=\(self.audioUnit == nil ? "nil" : "set", privacy: .public)")
        guard let audioUnit = self.audioUnit else { return }
        configureSwiftUIView(audioUnit: audioUnit)
    }

    public override func viewWillAppear() {
        super.viewWillAppear()
        log.info("viewWillAppear called, hostingView=\(self.hostingView == nil ? "nil" : "set", privacy: .public)")
        guard let audioUnit = self.audioUnit else { return }
        if hostingView == nil || hostingView?.superview == nil {
            configureSwiftUIView(audioUnit: audioUnit)
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

			defer {
				DispatchQueue.main.async {
					log.info("createAudioUnit defer: configuring SwiftUI view")
					self.configureSwiftUIView(audioUnit: audioUnit)
				}
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
        let hv = NSHostingView(rootView: content)
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
