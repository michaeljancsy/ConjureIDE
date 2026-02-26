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
    var audioUnit: AUAudioUnit?

    var hostingController: HostingController<TestPluginExtensionMainView>?

	deinit {
	}

    public override func viewDidLoad() {
        super.viewDidLoad()

        // Accessing the `audioUnit` parameter prompts the AU to be created via createAudioUnit(with:)
        guard let audioUnit = self.audioUnit else {
            return
        }
        configureSwiftUIView(audioUnit: audioUnit)
    }

	nonisolated public func createAudioUnit(with componentDescription: AudioComponentDescription) throws -> AUAudioUnit {
		return try DispatchQueue.main.sync {

			audioUnit = try TestPluginExtensionAudioUnit(componentDescription: componentDescription, options: [])

			guard let audioUnit = self.audioUnit as? TestPluginExtensionAudioUnit else {
				log.error("Unable to create TestPluginExtensionAudioUnit")
				return audioUnit!
			}

			defer {
				// Configure the SwiftUI view after creating the AU
				DispatchQueue.main.async {
					self.configureSwiftUIView(audioUnit: audioUnit)
				}
			}

			return audioUnit
		}
	}

    private func configureSwiftUIView(audioUnit: AUAudioUnit) {
        if let host = hostingController {
            host.removeFromParent()
            host.view.removeFromSuperview()
        }

        // Read the default process.py source from the bundle
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
        let host = HostingController(rootView: content)
        self.addChild(host)
        host.view.frame = self.view.bounds
        self.view.addSubview(host.view)
        hostingController = host

        // Make sure the SwiftUI view fills the full area provided by the view controller
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.topAnchor.constraint(equalTo: self.view.topAnchor).isActive = true
        host.view.leadingAnchor.constraint(equalTo: self.view.leadingAnchor).isActive = true
        host.view.trailingAnchor.constraint(equalTo: self.view.trailingAnchor).isActive = true
        host.view.bottomAnchor.constraint(equalTo: self.view.bottomAnchor).isActive = true
        self.view.bringSubviewToFront(host.view)
    }

}
