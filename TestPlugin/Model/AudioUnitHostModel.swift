//
//  AudioUnitHostModel.swift
//  TestPlugin
//
//  Created by Michael Jancsy on 2/25/26.
//

import SwiftUI
import CoreMIDI
import AudioToolbox
import AVFAudio

@MainActor
@Observable
class AudioUnitHostModel {
    /// The playback engine used to play audio.
    private let playEngine = SimplePlayEngine()

    /// The model providing information about the current Audio Unit
    var viewModel = AudioUnitViewModel()

    var isPlaying: Bool { playEngine.isPlaying }
    
    var audioUnitCrashed = false

    /// Audio Component Description
    let type: String
    let subType: String
    let manufacturer: String

    let wantsAudio: Bool
    let wantsMIDI: Bool
    let isFreeRunning: Bool

    let auValString: String
    
    private let instanceInvalidationNotifcation = Notification.Name(String(kAudioComponentInstanceInvalidationNotification))

    var validationResult: AudioComponentValidationResult?
    var currentValidationData: String?
    
    /// Reads the AU identity from the embedded extension's Info.plist.
    /// This is reliable regardless of what's registered system-wide (avoids stale pluginkit registrations).
    private static func discoverExtensionIdentity() -> (type: String, subType: String, manufacturer: String)? {
        guard let plugInsURL = Bundle.main.builtInPlugInsURL else { return nil }
        let appexURL = plugInsURL.appendingPathComponent("TestPluginExtension.appex")
        let plistURL = appexURL.appendingPathComponent("Contents/Info.plist")
        guard let plistData = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let nsExtension = plist["NSExtension"] as? [String: Any],
              let attrs = nsExtension["NSExtensionAttributes"] as? [String: Any],
              let components = attrs["AudioComponents"] as? [[String: Any]],
              let component = components.first,
              let type = component["type"] as? String,
              let subtype = component["subtype"] as? String,
              let manufacturer = component["manufacturer"] as? String
        else { return nil }
        return (type: type, subType: subtype, manufacturer: manufacturer)
    }

    private static func stringFromCode(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        return String(bytes.map { Character(UnicodeScalar($0)) })
    }

    init() {
        if let identity = Self.discoverExtensionIdentity() {
            self.type = identity.type
            self.subType = identity.subType
            self.manufacturer = identity.manufacturer
        } else {
            self.type = "aufx"
            self.subType = "????"
            self.manufacturer = "A000"
        }

        let wantsAudio = type.fourCharCode == kAudioUnitType_MusicEffect || type.fourCharCode == kAudioUnitType_Effect
        self.wantsAudio = wantsAudio

        let wantsMIDI = type.fourCharCode == kAudioUnitType_MIDIProcessor ||
        type.fourCharCode == kAudioUnitType_MusicDevice ||
        type.fourCharCode == kAudioUnitType_MusicEffect
        self.wantsMIDI = wantsMIDI

        let isFreeRunning = type.fourCharCode == kAudioUnitType_MIDIProcessor ||
        type.fourCharCode == kAudioUnitType_MusicDevice ||
        type.fourCharCode == kAudioUnitType_Generator
        self.isFreeRunning = isFreeRunning

        auValString = "\(type) \(subType) \(manufacturer)"

        setupNotifications()

        if subType == "????" {
            self.viewModel = AudioUnitViewModel(showAudioControls: false,
                                                showMIDIContols: false,
                                                title: "Error",
                                                message: "Failed to read AU identity from embedded extension. The build may be broken.",
                                                viewController: nil)
        } else {
            loadAudioUnit()
        }
    }

    private func loadAudioUnit() {
        Task {
            let viewController = await playEngine.initComponent(type: type, subType: subType, manufacturer: manufacturer)

            if let audioUnit = playEngine.avAudioUnit {
                Task { @MainActor in
                    let (validationResult, validationData) = await validateAU(audioUnit: audioUnit)
                    self.validationResult = validationResult
                    self.currentValidationData = validationData
                }
                self.viewModel = AudioUnitViewModel(showAudioControls: self.wantsAudio,
                                                    showMIDIContols: self.wantsMIDI,
                                                    title: self.auValString,
                                                    message: "Successfully loaded (\(self.auValString))",
                                                    viewController: viewController)

                if self.isFreeRunning {
                    self.playEngine.startPlaying()
                }
            } else {
                self.viewModel = AudioUnitViewModel(showAudioControls: false,
                                                    showMIDIContols: false,
                                                    title: self.auValString,
                                                    message: "Failed to find Audio Unit component (\(self.auValString)). Try relaunching the app.",
                                                    viewController: nil)
            }
        }
    }
    
    private func setupNotifications() {
        let notificationName = Notification.Name(instanceInvalidationNotifcation.rawValue)
        NotificationCenter.default.addObserver(forName: notificationName, object: nil, queue: nil) { [weak self] notification in
            guard let self = self else { return }
            if let _ = notification.object as? AUAudioUnit {
                Task { @MainActor in
                    self.audioUnitCrashed = true
                }
            }
        }
    }
    
    private func validateAU(audioUnit: AVAudioUnit) async -> (AudioComponentValidationResult, String) {
        await withCheckedContinuation { continuation in
            let validationParameters: [String: Any] = ["ForceValidation": true]

            AudioComponentValidateWithResults(audioUnit.auAudioUnit.component, validationParameters as CFDictionary) { @Sendable result, output in
                let formattedOutput: String

                if let validationDict = output as? [String: Any],
                   let rawOutput = validationDict["Output"] as? [String] {
                    formattedOutput = rawOutput.joined(separator: "\n")
                } else {
                    formattedOutput = "Validation probably crashed"
                }

                print(formattedOutput)
                
                continuation.resume(returning: (result, formattedOutput))
            }
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self, name: instanceInvalidationNotifcation, object: nil)
    }

    func startPlaying() {
        playEngine.startPlaying()
    }

    func stopPlaying() {
        playEngine.stopPlaying()
    }
}
