//
//  SimplePlayEngine.swift
//  ConjureDSP
//
//  Created by Michael Jancsy on 2/25/26.
//

import Foundation
import CoreAudioKit
import AVFoundation
@preconcurrency import AVFAudio

#if os(iOS) || os(visionOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Wraps and Audio Unit extension and provides helper functions.
extension AVAudioUnit {

    var wantsAudioInput: Bool {
        let componentType = self.auAudioUnit.componentDescription.componentType
        return componentType == kAudioUnitType_MusicEffect || componentType == kAudioUnitType_Effect
    }
    
	fileprivate func loadAudioUnitViewController() async -> ViewController? {
		let viewController = await auAudioUnit.requestViewController()

		if #available(macOS 13.0, iOS 16.0, *) {
			if viewController == nil {
				let genericViewController = await AUGenericViewController()
				await MainActor.run {
					genericViewController.auAudioUnit = self.auAudioUnit
				}
				return genericViewController
			}
		}

		return viewController
	}
}

/// Manages the interaction with the AudioToolbox and AVFoundation frameworks.
@MainActor
@Observable
public class SimplePlayEngine {
    
    var avAudioUnit: AVAudioUnit?
    
    // Synchronizes starting/stopping the engine and scheduling file segments.
    private let stateChangeQueue = DispatchQueue(label: "com.example.apple-samplecode.StateChangeQueue")
    
    // Playback engine.
    private let engine = AVAudioEngine()
    
    // Engine's player node.
    private let player = AVAudioPlayerNode()
    
    // File to play.
    private var file: AVAudioFile?
    
    // Whether we are playing.
    private(set) var isPlaying = false
    
    // This block will be called every render cycle and will receive MIDI events
    private let midiOutBlock: AUMIDIOutputEventBlock = { sampleTime, cable, length, data in return noErr }
    
    // This block can be used to send MIDI UMP events to the Audio Unit
    var scheduleMIDIEventListBlock: AUMIDIEventListBlock? = nil
    
    // MARK: Initialization
    
    public init() {
        engine.attach(player)
        
        guard let fileURL = Bundle.main.url(forResource: "Synth", withExtension: "aif") else {
            fatalError("\"Synth.aif\" file not found.")
        }
        setPlayerFile(fileURL)
        
        engine.prepare()
        setupMIDI()
    }
    
    private func setupMIDI() {
        if !MIDIManager.shared.setupPort(midiProtocol: MIDIProtocolID._2_0, receiveBlock: { [weak self] eventList, _ in
            if let scheduleMIDIEventListBlock = self?.scheduleMIDIEventListBlock {
                _ = scheduleMIDIEventListBlock(AUEventSampleTimeImmediate, 0, eventList)
            }
        }) {
            fatalError("Failed to setup Core MIDI")
        }
    }
    
    func initComponent(type: String, subType: String, manufacturer: String) async -> ViewController? {
        // Reset the engine to remove any configured audio units.
        reset()

        let description = AudioComponentDescription(
            componentType: type.fourCharCode!,
            componentSubType: subType.fourCharCode!,
            componentManufacturer: manufacturer.fourCharCode!,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        // Instantiate in-process — bypasses PluginKit registration which can be unreliable.
        do {
            let audioUnit = try await AVAudioUnit.instantiate(with: description, options: .loadInProcess)
            self.avAudioUnit = audioUnit
            self.connect(avAudioUnit: audioUnit)
            return await audioUnit.loadAudioUnitViewController()
        } catch {
            print("Failed to instantiate AU (\(type) \(subType) \(manufacturer)): \(error)")
            return nil
        }
    }
    
    private func setPlayerFile(_ fileURL: URL) {
        do {
            let file = try AVAudioFile(forReading: fileURL)
            self.file = file
            engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
        } catch {
            fatalError("Could not create AVAudioFile instance. error: \(error).")
        }
    }
    
    /// Changes the audio file at runtime. Stops and restarts playback as needed,
    /// and rewires through the AU if one is connected.
    public func setAudioFile(_ fileURL: URL) throws {
        let wasPlaying = isPlaying
        if wasPlaying {
            stopPlaying()
        }

        let newFile = try AVAudioFile(forReading: fileURL)
        self.file = newFile

        if let avAudioUnit = self.avAudioUnit, avAudioUnit.wantsAudioInput {
            // Rewire: player → AU → mixer with new format
            engine.disconnectNodeInput(avAudioUnit)
            engine.disconnectNodeInput(engine.mainMixerNode)
            engine.connect(player, to: avAudioUnit, format: newFile.processingFormat)
            engine.connect(avAudioUnit, to: engine.mainMixerNode, format: newFile.processingFormat)
        } else {
            // No AU or AU doesn't want audio input: player → mixer
            engine.connect(player, to: engine.mainMixerNode, format: newFile.processingFormat)
        }

        if wasPlaying {
            startPlaying()
        }
    }

    private func setSessionActive(_ active: Bool) {
#if os(iOS) || os(visionOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(active)
        } catch {
            fatalError("Could not set Audio Session active \(active). error: \(error).")
        }
#endif
    }
    
    // MARK: Playback State
    
    public func startPlaying() {
        stateChangeQueue.sync {
            if !self.isPlaying { self.startPlayingInternal() }
        }
    }
    
    public func stopPlaying() {
        stateChangeQueue.sync {
            if self.isPlaying { self.stopPlayingInternal() }
        }
    }
    
    public func togglePlay() -> Bool {
        if isPlaying {
            stopPlaying()
        } else {
            startPlaying()
        }
        return isPlaying
    }
    
    private func startPlayingInternal() {
        guard let avAudioUnit = self.avAudioUnit else {
            return
        }
        
        // assumptions: we are protected by stateChangeQueue. we are not playing.
        setSessionActive(true)
        
        if avAudioUnit.wantsAudioInput {
            // Schedule buffers on the player.
            scheduleEffectLoop()
        }
        
        let hardwareFormat = engine.outputNode.outputFormat(forBus: 0)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: hardwareFormat)
        
        // Start the engine.
        do {
            try engine.start()
        } catch {
            isPlaying = false
            fatalError("Could not start engine. error: \(error).")
        }

        if avAudioUnit.wantsAudioInput {
            // macOS 26 tightened AVFAudio's preconditions on AVAudioPlayerNode.
            // engine.start() returns as soon as it hands control to the audio
            // I/O thread, but that thread takes a few ms to render its first
            // tick. Calling player.play() before that first tick lands throws
            //
            //   *** Terminating app due to uncaught exception
            //   'com.apple.coreaudio.avfaudio',
            //   reason: 'player did not see an IO cycle.'
            //
            // outputNode.lastRenderTime is nil until the I/O thread emits its
            // first sample, so spin briefly until either it goes non-nil or we
            // hit a generous safety deadline. In practice this loop exits in
            // 1–3 iterations (~1–3 ms) on M-series hardware.
            let deadline = Date().addingTimeInterval(0.5)
            while engine.outputNode.lastRenderTime == nil && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.001)
            }
            player.play()
        }

        isPlaying = true
    }
    
    private func stopPlayingInternal() {
        guard let avAudioUnit = self.avAudioUnit else {
            return
        }
        
        if avAudioUnit.wantsAudioInput {
            player.stop()
        }
        engine.stop()
        isPlaying = false
        setSessionActive(false)
    }
    
    private func scheduleEffectLoop() {
        guard let file = file else {
            fatalError("`file` must not be nil in \(#function).")
        }
        
        Task {
            await player.scheduleFile(file, at: nil)
            if self.isPlaying {
                self.scheduleEffectLoop()
            }
        }
    }
    
    private func resetAudioLoop() {
        guard let avAudioUnit = self.avAudioUnit else {
            return
        }
        
        if avAudioUnit.wantsAudioInput {
            // Connect player -> mixer.
            guard let format = file?.processingFormat else { fatalError("No AVAudioFile defined (processing format unavailable).") }
            engine.connect(player, to: engine.mainMixerNode, format: format)
        }
    }
    
    public func reset() {
        connect(avAudioUnit: nil)
    }
    
    public func connect(avAudioUnit: AVAudioUnit?, completion: @escaping (() -> Void) = {}) {
        guard let avAudioUnit = self.avAudioUnit else {
            return
        }
        
        // Break the audio unit -> mixer connection
        engine.disconnectNodeInput(engine.mainMixerNode)
        
        resetAudioLoop()
        
        // We're done with the unit; release all references.
        engine.detach(avAudioUnit)
        
        // Internal function to resume playing and call the completion handler.
        func rewiringComplete() {
            scheduleMIDIEventListBlock = auAudioUnit.scheduleMIDIEventListBlock
            if isPlaying {
                player.play()
            }
            completion()
        }
        
        let hardwareFormat = engine.outputNode.outputFormat(forBus: 0)
        
        // Connect the main mixer -> output node
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: hardwareFormat)
        
        // Pause the player before re-wiring it. It is not simple to keep it playing across an insertion or deletion.
        if isPlaying {
            player.pause()
        }
        
        let auAudioUnit = avAudioUnit.auAudioUnit
        
        if !auAudioUnit.midiOutputNames.isEmpty {
            auAudioUnit.midiOutputEventBlock = midiOutBlock
        }
        
        // Attach the AVAudioUnit the graph.
        engine.attach(avAudioUnit)
        
        if avAudioUnit.wantsAudioInput {
            // Disconnect the player -> mixer.
            engine.disconnectNodeInput(engine.mainMixerNode)
            
            // Connect the player -> effect -> mixer.
            if let format = file?.processingFormat {
                engine.connect(player, to: avAudioUnit, format: format)
                engine.connect(avAudioUnit, to: engine.mainMixerNode, format: format)
            }
        } else {
            let stereoFormat = AVAudioFormat(standardFormatWithSampleRate: hardwareFormat.sampleRate, channels: 2)
            engine.connect(avAudioUnit, to: engine.mainMixerNode, format: stereoFormat)
        }
        rewiringComplete()
    }
}
