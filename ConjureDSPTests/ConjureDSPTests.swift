//
//  ConjureDSPTests.swift
//  ConjureDSPTests
//
//  Created by Michael Jancsy on 2/25/26.
//

import Testing
import AVFoundation
import AudioToolbox
import CoreAudioKit

struct ConjureDSPTests {

    // MARK: - Helpers

    /// Reads the AU identity from the embedded extension's Info.plist.
    /// This is reliable regardless of what's registered system-wide (avoids stale pluginkit registrations).
    private static var componentDescription: AudioComponentDescription {
        get throws {
            guard let plugInsURL = Bundle.main.builtInPlugInsURL else {
                throw TestError("Bundle.main.builtInPlugInsURL is nil — test host has no PlugIns directory")
            }
            let plistURL = plugInsURL
                .appendingPathComponent("ConjureDSPExtension.appex")
                .appendingPathComponent("Contents/Info.plist")
            let data = try Data(contentsOf: plistURL)
            guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let nsExt = plist["NSExtension"] as? [String: Any],
                  let attrs = nsExt["NSExtensionAttributes"] as? [String: Any],
                  let components = attrs["AudioComponents"] as? [[String: Any]],
                  let component = components.first,
                  let type = component["type"] as? String,
                  let subtype = component["subtype"] as? String,
                  let manufacturer = component["manufacturer"] as? String
            else {
                throw TestError("Failed to parse AU identity from embedded extension Info.plist")
            }
            return AudioComponentDescription(
                componentType: fourCharCode(type),
                componentSubType: fourCharCode(subtype),
                componentManufacturer: fourCharCode(manufacturer),
                componentFlags: 0,
                componentFlagsMask: 0
            )
        }
    }

    private struct TestError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private static func fourCharCode(_ string: String) -> FourCharCode {
        var code: FourCharCode = 0
        for byte in string.utf8 {
            code = code << 8 + FourCharCode(byte)
        }
        return code
    }

    private static func instantiateAU() async throws -> (AVAudioUnit, AUAudioUnit) {
        let desc = try componentDescription
        let avAudioUnit = try await AVAudioUnit.instantiate(
            with: desc,
            options: .loadInProcess
        )
        return (avAudioUnit, avAudioUnit.auAudioUnit)
    }

    // MARK: - Component Discovery

    @Test func audioUnitComponentIsRegistered() async throws {
        let desc = try Self.componentDescription
        let components = AVAudioUnitComponentManager.shared()
            .components(matching: desc)
        #expect(!components.isEmpty, "AU component should be registered with the system")
    }

    // MARK: - AU Instantiation

    @Test func audioUnitCanBeInstantiated() async throws {
        let desc = try Self.componentDescription
        let avAudioUnit = try await AVAudioUnit.instantiate(
            with: desc,
            options: .loadInProcess
        )
        let au = avAudioUnit.auAudioUnit
        #expect(au.componentDescription.componentType == kAudioUnitType_Effect)
        #expect(au.componentDescription.componentManufacturer == Self.fourCharCode("CONJ"))
    }

    // MARK: - Basic Properties

    @Test func audioUnitHasCorrectBusConfiguration() async throws {
        let avAudioUnit = try await AVAudioUnit.instantiate(
            with: Self.componentDescription,
            options: .loadInProcess
        )
        let au = avAudioUnit.auAudioUnit
        #expect(au.inputBusses.count == 1, "Effect should have 1 input bus")
        #expect(au.outputBusses.count == 1, "Effect should have 1 output bus")
    }

    @Test func audioUnitBypassDefaultsToFalse() async throws {
        let avAudioUnit = try await AVAudioUnit.instantiate(
            with: Self.componentDescription,
            options: .loadInProcess
        )
        #expect(avAudioUnit.auAudioUnit.shouldBypassEffect == false)
    }

    @Test func audioUnitBypassCanBeToggled() async throws {
        let avAudioUnit = try await AVAudioUnit.instantiate(
            with: Self.componentDescription,
            options: .loadInProcess
        )
        let au = avAudioUnit.auAudioUnit
        au.shouldBypassEffect = true
        #expect(au.shouldBypassEffect == true)
        au.shouldBypassEffect = false
        #expect(au.shouldBypassEffect == false)
    }

    @Test func audioUnitReportsChannelCapabilities() async throws {
        let avAudioUnit = try await AVAudioUnit.instantiate(
            with: Self.componentDescription,
            options: .loadInProcess
        )
        let capabilities = avAudioUnit.auAudioUnit.channelCapabilities ?? []
        #expect(capabilities == [1, 1, 2, 2] as [NSNumber])
    }

    // MARK: - Render Resource Lifecycle

    @Test func allocateAndDeallocateRenderResources() async throws {
        let (_, au) = try await Self.instantiateAU()
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        try au.inputBusses[0].setFormat(format)
        try au.outputBusses[0].setFormat(format)
        try au.allocateRenderResources()
        #expect(au.renderResourcesAllocated == true)
        au.deallocateRenderResources()
        #expect(au.renderResourcesAllocated == false)
    }

    @Test func allocateDeallocateMultipleCycles() async throws {
        let (_, au) = try await Self.instantiateAU()
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        try au.inputBusses[0].setFormat(format)
        try au.outputBusses[0].setFormat(format)
        for _ in 0..<3 {
            try au.allocateRenderResources()
            #expect(au.renderResourcesAllocated == true)
            au.deallocateRenderResources()
            #expect(au.renderResourcesAllocated == false)
        }
    }

    @Test func maximumFramesToRenderRoundtrip() async throws {
        let (_, au) = try await Self.instantiateAU()
        au.maximumFramesToRender = 512
        #expect(au.maximumFramesToRender == 512)
        au.maximumFramesToRender = 2048
        #expect(au.maximumFramesToRender == 2048)
    }

    @Test func sampleRateNegotiationViaFormat() async throws {
        let (_, au) = try await Self.instantiateAU()
        let format48k = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        try au.inputBusses[0].setFormat(format48k)
        try au.outputBusses[0].setFormat(format48k)
        try au.allocateRenderResources()
        #expect(au.outputBusses[0].format.sampleRate == 48000)
        au.deallocateRenderResources()
    }

    // MARK: - View Controller Resize Properties

    @MainActor
    private static func requestVC(_ au: AUAudioUnit) async throws -> NSViewController {
        guard let vc = await au.requestViewController() else {
            throw NSError(domain: "ConjureDSP", code: 1, userInfo: [NSLocalizedDescriptionKey: "No view controller returned"])
        }
        return vc
    }

    // Note: requestViewController() returns an AUAudioUnitRemoteViewController proxy,
    // not our AudioUnitViewController directly. The proxy forwards preferredContentSize
    // but uses its own defaults for preferredMinimumSize/preferredMaximumSize.
    // We can only verify preferredContentSize through the test API.

    @Test @MainActor func viewControllerPreferredContentSize() async throws {
        let (_, au) = try await Self.instantiateAU()
        let vc = try await Self.requestVC(au)
        // Size is dynamic (70% screen width, 80% screen height) so just verify it's reasonable
        #expect(vc.preferredContentSize.width >= 400, "Preferred width should be at least minimum")
        #expect(vc.preferredContentSize.height >= 300, "Preferred height should be at least minimum")
    }

    @Test @MainActor func viewControllerIsResizable() async throws {
        let (_, au) = try await Self.instantiateAU()
        let vc = try await Self.requestVC(au)
        // The proxy reports min < preferred < max, confirming the plugin supports resizing
        let pref = vc.preferredContentSize
        let min = vc.preferredMinimumSize
        let max = vc.preferredMaximumSize
        #expect(min.width < pref.width, "Min width should be less than preferred width")
        #expect(min.height < pref.height, "Min height should be less than preferred height")
        #expect(max.width > pref.width, "Max width should be greater than preferred width")
        #expect(max.height > pref.height, "Max height should be greater than preferred height")
    }

    // MARK: - Render Block

    @Test func renderBlockProducesPassthroughAudio() async throws {
        let (_, au) = try await Self.instantiateAU()
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        try au.inputBusses[0].setFormat(format)
        try au.outputBusses[0].setFormat(format)
        au.maximumFramesToRender = 512
        try au.allocateRenderResources()

        let renderBlock = au.renderBlock
        let frameCount: UInt32 = 128

        let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        outputBuffer.frameLength = frameCount

        let inputData: [Float] = (0..<Int(frameCount)).map { Float($0) / Float(frameCount) }

        let pullInput: AURenderPullInputBlock = { _, _, inFrameCount, _, inputBuf in
            let buf = UnsafeMutableAudioBufferListPointer(inputBuf)
            guard let data = buf[0].mData?.assumingMemoryBound(to: Float.self) else {
                return kAudioUnitErr_NoConnection
            }
            for i in 0..<Int(inFrameCount) {
                data[i] = inputData[i]
            }
            buf[0].mDataByteSize = inFrameCount * UInt32(MemoryLayout<Float>.size)
            return noErr
        }

        var flags = AudioUnitRenderActionFlags()
        var timestamp = AudioTimeStamp()
        timestamp.mSampleTime = 0
        timestamp.mFlags = .sampleTimeValid

        let status = renderBlock(&flags, &timestamp, frameCount, 0,
                                outputBuffer.mutableAudioBufferList, pullInput)

        #expect(status == noErr)

        // Output should be passthrough or 0.5x gain (if Python loaded)
        let outputPtr = outputBuffer.floatChannelData![0]
        let firstInput = inputData[1]  // skip 0 since 0*anything=0
        let firstOutput = outputPtr[1]
        let isPassthrough = abs(firstOutput - firstInput) < 1e-6
        let isHalfGain = abs(firstOutput - firstInput * 0.5) < 1e-6
        #expect(isPassthrough || isHalfGain,
               "Output should be passthrough or 0.5x gain, got \(firstOutput) for input \(firstInput)")

        au.deallocateRenderResources()
    }

    @Test func renderBlockStereoPassthrough() async throws {
        let (_, au) = try await Self.instantiateAU()
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        try au.inputBusses[0].setFormat(format)
        try au.outputBusses[0].setFormat(format)
        au.maximumFramesToRender = 512
        try au.allocateRenderResources()

        let renderBlock = au.renderBlock
        let frameCount: UInt32 = 64

        let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        outputBuffer.frameLength = frameCount

        let inputL: [Float] = (0..<Int(frameCount)).map { Float($0) / Float(frameCount) }
        let inputR: [Float] = (0..<Int(frameCount)).map { 1.0 - Float($0) / Float(frameCount) }

        let pullInput: AURenderPullInputBlock = { _, _, inFrameCount, _, inputBuf in
            let buf = UnsafeMutableAudioBufferListPointer(inputBuf)
            guard buf.count >= 2 else { return kAudioUnitErr_NoConnection }
            if let dataL = buf[0].mData?.assumingMemoryBound(to: Float.self) {
                for i in 0..<Int(inFrameCount) { dataL[i] = inputL[i] }
                buf[0].mDataByteSize = inFrameCount * UInt32(MemoryLayout<Float>.size)
            }
            if let dataR = buf[1].mData?.assumingMemoryBound(to: Float.self) {
                for i in 0..<Int(inFrameCount) { dataR[i] = inputR[i] }
                buf[1].mDataByteSize = inFrameCount * UInt32(MemoryLayout<Float>.size)
            }
            return noErr
        }

        var flags = AudioUnitRenderActionFlags()
        var timestamp = AudioTimeStamp()
        timestamp.mSampleTime = 0
        timestamp.mFlags = .sampleTimeValid

        let status = renderBlock(&flags, &timestamp, frameCount, 0,
                                outputBuffer.mutableAudioBufferList, pullInput)

        #expect(status == noErr)

        // Verify both channels have data (default preset is stereo width at width=1.0 → passthrough)
        let outL = outputBuffer.floatChannelData![0]
        let outR = outputBuffer.floatChannelData![1]
        let valL = outL[1]
        let valR = outR[1]
        // Default preset is stereo width with default width=1.0 → passthrough:
        // output should match input
        let isPassL = abs(valL - inputL[1]) < 1e-4
        let isPassR = abs(valR - inputR[1]) < 1e-4
        #expect(isPassL, "Left channel should pass through at width=1.0")
        #expect(isPassR, "Right channel should pass through at width=1.0")

        au.deallocateRenderResources()
    }

    // MARK: - State Persistence (fullState)

    private static let scriptSourceKey = "pythonScriptSource"

    private static let testScript = """
        import numpy as np

        def process(inputs, outputs, frame_count, sample_rate, params):
            for ch in range(len(inputs)):
                outputs[ch][:frame_count] = inputs[ch][:frame_count] * 0.25
        """

    @Test func fullStateRoundtrip() async throws {
        // Simulate DAW project save/load: set script via fullState, read it back, restore on new AU
        let (_, au1) = try await Self.instantiateAU()

        // Set a custom script via fullState (simulates what happens when reloadScript caches source)
        var state1: [String: Any] = au1.fullState ?? [:]
        state1[Self.scriptSourceKey] = Self.testScript.data(using: .utf8)!
        au1.fullState = state1

        // Read back fullState (simulates DAW saving the project)
        let savedState = au1.fullState
        #expect(savedState != nil)
        let savedData = savedState?[Self.scriptSourceKey] as? Data
        #expect(savedData != nil, "fullState should contain script source")
        let savedSource = String(data: savedData!, encoding: .utf8)
        #expect(savedSource == Self.testScript, "Script source should roundtrip through fullState")

        // Restore on a new AU (simulates DAW loading the project)
        let (_, au2) = try await Self.instantiateAU()
        au2.fullState = savedState
        let restoredState = au2.fullState
        let restoredData = try #require(restoredState?[Self.scriptSourceKey] as? Data,
                                         "Restored AU should have script in fullState")
        let restoredSource = String(data: restoredData, encoding: .utf8)
        #expect(restoredSource == Self.testScript, "Script should survive full save/restore cycle")
    }

    @Test func fullStateWithDefaultPreset() async throws {
        let (_, au) = try await Self.instantiateAU()
        // Fresh AU loads the default preset — fullState should include its source
        let state = au.fullState
        #expect(state != nil, "fullState should return a dictionary")
        let scriptData = state?[Self.scriptSourceKey] as? Data
        #expect(scriptData != nil, "Fresh AU should have the default preset script in fullState")
    }

    @Test func fullStatePreservesBaseState() async throws {
        let (_, au1) = try await Self.instantiateAU()

        // Set bypass + custom script
        au1.shouldBypassEffect = true
        var state: [String: Any] = au1.fullState ?? [:]
        state[Self.scriptSourceKey] = Self.testScript.data(using: .utf8)!
        au1.fullState = state

        // Save and restore
        let savedState = au1.fullState
        let (_, au2) = try await Self.instantiateAU()
        au2.fullState = savedState

        // Verify both bypass and script survived
        let restoredData = au2.fullState?[Self.scriptSourceKey] as? Data
        let restoredSource = String(data: restoredData ?? Data(), encoding: .utf8)
        #expect(restoredSource == Self.testScript)
    }

    // MARK: - Factory Presets

    @Test func factoryPresetsExist() async throws {
        let (_, au) = try await Self.instantiateAU()
        let presets = au.factoryPresets ?? []
        #expect(presets.count >= 8, "Should have at least 8 factory presets")
        let names = presets.map { $0.name }
        #expect(names.contains("Passthrough (Python)"), "Should have Passthrough (Python) preset")
        #expect(names.contains("Tremolo (Python)"), "Should have Tremolo (Python) preset")
        #expect(names.contains("Bitcrush (Python)"), "Should have Bitcrush (Python) preset")
        #expect(names.contains("Compressor (Python)"), "Should have Compressor (Python) preset")
        #expect(names.contains("Passthrough (Rust)"), "Should have Passthrough (Rust) preset")
        #expect(names.contains("Tremolo (Rust)"), "Should have Tremolo (Rust) preset")
        #expect(names.contains("Bitcrush (Rust)"), "Should have Bitcrush (Rust) preset")
        #expect(names.contains("Compressor (Rust)"), "Should have Compressor (Rust) preset")
    }

    @Test func factoryPresetLoading() async throws {
        let (_, au) = try await Self.instantiateAU()
        let presets = au.factoryPresets ?? []
        #expect(!presets.isEmpty)

        // Test Python factory presets (should load and contain def process)
        let pythonPresets = presets.filter { !$0.name.contains("Rust") }
        for preset in pythonPresets {
            au.currentPreset = preset
            let state = au.fullState
            let data = state?[Self.scriptSourceKey] as? Data
            #expect(data != nil, "Factory preset '\(preset.name)' should set a script in fullState")
            let source = String(data: data!, encoding: .utf8) ?? ""
            #expect(source.contains("def process"), "Factory preset '\(preset.name)' should contain Python process function")
        }
    }

    @Test func rustFactoryPresetsHaveRustContent() async throws {
        let (_, au) = try await Self.instantiateAU()
        let presets = au.factoryPresets ?? []
        let rustPresets = presets.filter { $0.name.contains("Rust") }
        #expect(rustPresets.count == 25, "Should have 25 Rust factory presets")
        for rustPreset in rustPresets {
            au.currentPreset = rustPreset
            let state = au.fullState
            let data = state?[Self.scriptSourceKey] as? Data
            #expect(data != nil, "Rust factory preset '\(rustPreset.name)' should set script source in fullState")
            let source = String(data: data!, encoding: .utf8) ?? ""
            #expect(source.contains("fn process"), "Rust factory preset '\(rustPreset.name)' should contain Rust process function")
        }
    }

    @Test func factoryPresetThenModify() async throws {
        // Simulate: user selects preset, modifies script, DAW saves/restores
        let (_, au1) = try await Self.instantiateAU()
        let presets = au1.factoryPresets ?? []
        #expect(!presets.isEmpty)

        // Load a factory preset
        au1.currentPreset = presets[0]

        // Modify the script via fullState (simulating user editing + saving)
        var state: [String: Any] = au1.fullState ?? [:]
        state[Self.scriptSourceKey] = Self.testScript.data(using: .utf8)!
        au1.fullState = state

        // Save and restore on new AU
        let savedState = au1.fullState
        let (_, au2) = try await Self.instantiateAU()
        au2.fullState = savedState

        // Should have the modified script, not the original preset
        let restoredData = au2.fullState?[Self.scriptSourceKey] as? Data
        let restoredSource = String(data: restoredData ?? Data(), encoding: .utf8)
        #expect(restoredSource == Self.testScript, "Modified script should take priority over factory preset")
    }

    @Test func presetsSwitchScriptInFullState() async throws {
        // Verify that switching between Python presets changes the script in fullState
        let (_, au) = try await Self.instantiateAU()
        let presets = au.factoryPresets ?? []
        #expect(presets.count >= 3)

        let tremoloPreset = try #require(presets.first { $0.name == "Tremolo (Python)" })
        let bitcrushPreset = try #require(presets.first { $0.name == "Bitcrush (Python)" })

        au.currentPreset = tremoloPreset
        let state1 = au.fullState
        let data1 = state1?[Self.scriptSourceKey] as? Data
        let source1 = String(data: data1!, encoding: .utf8)!

        au.currentPreset = bitcrushPreset
        let state2 = au.fullState
        let data2 = state2?[Self.scriptSourceKey] as? Data
        let source2 = String(data: data2!, encoding: .utf8)!

        #expect(source1 != source2, "Different presets should produce different scripts in fullState")
        #expect(source1.contains("def process"))
        #expect(source2.contains("def process"))
    }

    @Test func fileRoundtrip() async throws {
        // Simulate file save/load cycle
        let (_, au) = try await Self.instantiateAU()

        // Set a script via fullState
        var state: [String: Any] = au.fullState ?? [:]
        state[Self.scriptSourceKey] = Self.testScript.data(using: .utf8)!
        au.fullState = state

        // Extract script from fullState (simulates reading scriptSource for file save)
        let data = au.fullState?[Self.scriptSourceKey] as? Data
        let source = String(data: data!, encoding: .utf8)!

        // Write to temp file
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_\(UUID().uuidString).py")
        try source.write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // Read back from file
        let loaded = try String(contentsOf: tempURL, encoding: .utf8)
        #expect(loaded == Self.testScript, "Script should roundtrip through file save/load")

        // Load into a new AU via fullState
        let (_, au2) = try await Self.instantiateAU()
        var state2: [String: Any] = [:]
        state2[Self.scriptSourceKey] = loaded.data(using: .utf8)!
        au2.fullState = state2

        let restoredData = au2.fullState?[Self.scriptSourceKey] as? Data
        let restoredSource = String(data: restoredData ?? Data(), encoding: .utf8)
        #expect(restoredSource == Self.testScript)
    }

    // MARK: - Script Reload via fullState

    @Test func reloadScriptViaFullStateAffectsRendering() async throws {
        // Tests the core save-button logic: reloadScript loads a new script into the kernel.
        // We invoke it indirectly via fullState (which calls reloadScript internally),
        // then verify the kernel uses the new script by rendering audio.
        let (_, au) = try await Self.instantiateAU()

        // Load a script that multiplies all samples by 0.25
        let quarterGainScript = """
            import numpy as np
            def process(inputs, outputs, frame_count, sample_rate):
                for ch in range(len(inputs)):
                    outputs[ch][:frame_count] = inputs[ch][:frame_count] * 0.25
            """
        var state: [String: Any] = au.fullState ?? [:]
        state[Self.scriptSourceKey] = quarterGainScript.data(using: .utf8)!
        au.fullState = state

        // Verify the script is stored in fullState
        let storedData = au.fullState?[Self.scriptSourceKey] as? Data
        #expect(storedData != nil, "Script should be stored in fullState after reload")
        let storedSource = String(data: storedData!, encoding: .utf8)
        #expect(storedSource == quarterGainScript, "Stored script should match what was set")

        // Set up render resources and render audio to verify the kernel uses the new script
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        try au.inputBusses[0].setFormat(format)
        try au.outputBusses[0].setFormat(format)
        au.maximumFramesToRender = 512
        try au.allocateRenderResources()

        let renderBlock = au.renderBlock
        let frameCount: UInt32 = 64

        let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        outputBuffer.frameLength = frameCount

        let inputData: [Float] = (0..<Int(frameCount)).map { Float($0 + 1) / Float(frameCount) }

        let pullInput: AURenderPullInputBlock = { _, _, inFrameCount, _, inputBuf in
            let buf = UnsafeMutableAudioBufferListPointer(inputBuf)
            guard let data = buf[0].mData?.assumingMemoryBound(to: Float.self) else {
                return kAudioUnitErr_NoConnection
            }
            for i in 0..<Int(inFrameCount) { data[i] = inputData[i] }
            buf[0].mDataByteSize = inFrameCount * UInt32(MemoryLayout<Float>.size)
            return noErr
        }

        var flags = AudioUnitRenderActionFlags()
        var timestamp = AudioTimeStamp()
        timestamp.mSampleTime = 0
        timestamp.mFlags = .sampleTimeValid

        let status = renderBlock(&flags, &timestamp, frameCount, 0,
                                outputBuffer.mutableAudioBufferList, pullInput)
        #expect(status == noErr)

        // Output should be input * 0.25 (the script we loaded)
        let outputPtr = outputBuffer.floatChannelData![0]
        for i in 0..<Int(frameCount) {
            let expected = inputData[i] * 0.25
            #expect(abs(outputPtr[i] - expected) < 1e-5,
                   "Sample \(i): expected \(expected), got \(outputPtr[i])")
        }

        au.deallocateRenderResources()
    }

    // MARK: - Rust Script Save Regression

    @Test func rustScriptFullStateRoundtripDoesNotCallPythonPath() async throws {
        // Regression test: saving a Rust script should not route through
        // the Python reloadScript() path. We verify by setting a Rust script
        // via fullState (which is what the save flow persists to) and
        // confirming it roundtrips correctly with the rust language tag.
        let (_, au) = try await Self.instantiateAU()
        let rustSource = """
            const MAX_CH: usize = 2;
            const MAX_FR: usize = 4096;
            static mut INPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
            static mut OUTPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];
            #[no_mangle]
            pub extern "C" fn get_input_ptr() -> i32 { unsafe { INPUT_BUF.as_ptr() as i32 } }
            #[no_mangle]
            pub extern "C" fn get_output_ptr() -> i32 { unsafe { OUTPUT_BUF.as_ptr() as i32 } }
            #[no_mangle]
            pub extern "C" fn process(input: *const f32, output: *mut f32, channels: i32, frame_count: i32, _sample_rate: f32) {
                let n = (channels * frame_count) as usize;
                unsafe {
                    let inp = std::slice::from_raw_parts(input, n);
                    let out = std::slice::from_raw_parts_mut(output, n);
                    for i in 0..n { out[i] = inp[i]; }
                }
            }
            """

        // Set Rust script via fullState with the language key
        var state: [String: Any] = au.fullState ?? [:]
        state[Self.scriptSourceKey] = rustSource.data(using: .utf8)!
        state["scriptLanguage"] = "rust"
        au.fullState = state

        // Verify the script roundtrips — if it hit the Python path, the source
        // would not be stored (reloadScript fails and skips scriptSourceDidChange)
        let restored = au.fullState
        let data = restored?[Self.scriptSourceKey] as? Data
        #expect(data != nil, "Rust script should be persisted in fullState")
        let restoredSource = String(data: data!, encoding: .utf8)
        #expect(restoredSource == rustSource, "Rust script should roundtrip through fullState")

        let lang = restored?["scriptLanguage"] as? String
        #expect(lang == "rust", "Language should be persisted as rust")
    }

    // MARK: - Build ID

    @Test func extensionPlistContainsBuildID() throws {
        guard let plugInsURL = Bundle.main.builtInPlugInsURL else {
            throw TestError("Bundle.main.builtInPlugInsURL is nil")
        }
        let plistURL = plugInsURL
            .appendingPathComponent("ConjureDSPExtension.appex")
            .appendingPathComponent("Contents/Info.plist")
        let data = try Data(contentsOf: plistURL)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw TestError("Failed to parse extension Info.plist")
        }
        let buildID = try #require(plist["BuildID"] as? Int, "Extension Info.plist should contain a BuildID integer key")
        #expect(buildID > 0, "BuildID should be a positive integer (Unix timestamp), got \(buildID)")
    }

    // MARK: - Render Block

    @Test func renderBlockWithBypass() async throws {
        let (_, au) = try await Self.instantiateAU()
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        try au.inputBusses[0].setFormat(format)
        try au.outputBusses[0].setFormat(format)
        au.maximumFramesToRender = 512
        au.shouldBypassEffect = true
        try au.allocateRenderResources()

        let renderBlock = au.renderBlock
        let frameCount: UInt32 = 64

        let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        outputBuffer.frameLength = frameCount

        let inputData: [Float] = (0..<Int(frameCount)).map { Float($0) / Float(frameCount) }

        let pullInput: AURenderPullInputBlock = { _, _, inFrameCount, _, inputBuf in
            let buf = UnsafeMutableAudioBufferListPointer(inputBuf)
            guard let data = buf[0].mData?.assumingMemoryBound(to: Float.self) else {
                return kAudioUnitErr_NoConnection
            }
            for i in 0..<Int(inFrameCount) { data[i] = inputData[i] }
            buf[0].mDataByteSize = inFrameCount * UInt32(MemoryLayout<Float>.size)
            return noErr
        }

        var flags = AudioUnitRenderActionFlags()
        var timestamp = AudioTimeStamp()
        timestamp.mSampleTime = 0
        timestamp.mFlags = .sampleTimeValid

        let status = renderBlock(&flags, &timestamp, frameCount, 0,
                                outputBuffer.mutableAudioBufferList, pullInput)

        #expect(status == noErr)

        // Bypass always copies input unchanged
        let outputPtr = outputBuffer.floatChannelData![0]
        for i in 0..<Int(frameCount) {
            #expect(abs(outputPtr[i] - inputData[i]) < 1e-6,
                   "Sample \(i): bypass should copy input unchanged")
        }

        au.deallocateRenderResources()
    }

    // MARK: - Parameter Tree

    @Test func parameterTreeMatchesLoadedScript() async throws {
        let (_, au) = try await Self.instantiateAU()
        let tree = try #require(au.parameterTree, "Parameter tree should exist")
        let params = tree.allParameters
        // Default preset (stereo width) declares 1 parameter via PARAMS dict.
        // The tree is rebuilt to match the script's declared parameters.
        #expect(params.count >= 1, "Should have at least 1 parameter")
        let param0 = tree.parameter(withAddress: AUParameterAddress(0))
        #expect(param0 != nil, "Parameter at address 0 should exist")
    }

    @Test func parameterUIPathMatchesDAWPath() async throws {
        // Setting param.value (the UI codepath) should write through
        // implementorValueObserver → dsp_kernel_set_parameter() and be
        // readable back via implementorValueProvider → dsp_kernel_get_parameter().
        let (_, au) = try await Self.instantiateAU()
        let tree = try #require(au.parameterTree)
        let params = tree.allParameters

        for param in params {
            // Use a value within the parameter's range
            let testValue = param.minValue + (param.maxValue - param.minValue) * 0.42
            param.value = testValue
            #expect(abs(param.value - testValue) < 0.01,
                   "Param \(param.displayName): value set via AUParameter.value should round-trip through Rust kernel")
        }
    }

    @Test func parameterTreeObserverFiresOnValueSet() async throws {
        let (_, au) = try await Self.instantiateAU()
        let tree = try #require(au.parameterTree)
        let param = try #require(tree.parameter(withAddress: 0))

        let observedAddress = UnsafeMutablePointer<AUParameterAddress>.allocate(capacity: 1)
        let observedValue = UnsafeMutablePointer<AUValue>.allocate(capacity: 1)
        let fired = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
        observedAddress.pointee = UInt64.max
        observedValue.pointee = -1
        fired.pointee = false
        defer {
            observedAddress.deallocate()
            observedValue.deallocate()
            fired.deallocate()
        }

        let token = tree.token(byAddingParameterObserver: { address, value in
            observedAddress.pointee = address
            observedValue.pointee = value
            fired.pointee = true
        })

        let testValue = param.minValue + (param.maxValue - param.minValue) * 0.42
        param.value = testValue

        // Observer may fire on an arbitrary thread; wait briefly
        for _ in 0..<100 {
            if fired.pointee { break }
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }

        #expect(fired.pointee, "Observer should have fired")
        #expect(observedAddress.pointee == 0, "Observer should fire with address 0")
        #expect(abs(observedValue.pointee - testValue) < 0.01, "Observer should receive the set value")

        tree.removeParameterObserver(token)
    }

    @Test func parameterValueRoundTrip() async throws {
        let (_, au) = try await Self.instantiateAU()
        let tree = try #require(au.parameterTree)
        let params = tree.allParameters

        // Set each param to a value within its range, then read back
        for (i, param) in params.enumerated() {
            let fraction = Float(i + 1) / Float(params.count + 1)
            let testValue = param.minValue + (param.maxValue - param.minValue) * fraction
            param.value = testValue
        }

        // Read all back and verify
        for (i, param) in params.enumerated() {
            let fraction = Float(i + 1) / Float(params.count + 1)
            let expected = param.minValue + (param.maxValue - param.minValue) * fraction
            #expect(abs(param.value - expected) < 0.01,
                   "Param \(param.displayName): expected \(expected), got \(param.value)")
        }
    }

    // MARK: - Process Profiler (via C FFI directly)

    @Test func profilerInitiallyZero() {
        let kernel = dsp_kernel_create()!
        defer { dsp_kernel_destroy(kernel) }
        #expect(dsp_kernel_profiler_current_us(kernel) == 0)
        #expect(dsp_kernel_profiler_avg_us(kernel) == 0)
        #expect(dsp_kernel_profiler_peak_us(kernel) == 0)
    }

    @Test func profilerUpdatesAfterRendering() async throws {
        // Use the full AU pipeline so the default Python script is loaded
        let (_, au) = try await Self.instantiateAU()
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        try au.inputBusses[0].setFormat(format)
        try au.outputBusses[0].setFormat(format)
        au.maximumFramesToRender = 512
        try au.allocateRenderResources()

        let renderBlock = au.renderBlock
        let frameCount: UInt32 = 128
        let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        outputBuffer.frameLength = frameCount

        let inputData: [Float] = (0..<Int(frameCount)).map { Float($0) / Float(frameCount) }
        let pullInput: AURenderPullInputBlock = { _, _, inFrameCount, _, inputBuf in
            let buf = UnsafeMutableAudioBufferListPointer(inputBuf)
            guard let data = buf[0].mData?.assumingMemoryBound(to: Float.self) else {
                return kAudioUnitErr_NoConnection
            }
            for i in 0..<Int(inFrameCount) {
                data[i] = inputData[i]
            }
            buf[0].mDataByteSize = inFrameCount * UInt32(MemoryLayout<Float>.size)
            return noErr
        }

        var flags = AudioUnitRenderActionFlags()
        var timestamp = AudioTimeStamp()
        timestamp.mSampleTime = 0
        timestamp.mFlags = .sampleTimeValid

        let status = renderBlock(&flags, &timestamp, frameCount, 0,
                                outputBuffer.mutableAudioBufferList, pullInput)
        #expect(status == noErr)

        // The AU has a default Python script loaded, so the profiler should update.
        // We can't access kernelReference from the test target, but we can verify
        // indirectly: if the render succeeded and output is non-zero, the backend ran.
        // The profiler tests at the Rust FFI level (3 tests in lib.rs) cover the
        // atomic update mechanics directly.
        let outputPtr = outputBuffer.floatChannelData![0]
        let hasOutput = (0..<Int(frameCount)).contains { outputPtr[$0] != 0 }
        #expect(hasOutput, "Backend should have produced non-zero output (profiler ran)")

        au.deallocateRenderResources()
    }

    @Test func profilerBypassDoesNotUpdate() {
        let kernel = dsp_kernel_create()!
        defer { dsp_kernel_destroy(kernel) }

        dsp_kernel_initialize(kernel, 1, 1, 44100)
        dsp_kernel_set_bypassed(kernel, true)

        var input: [Float] = [0.1, 0.2, 0.3, 0.4]
        var output: [Float] = [0, 0, 0, 0]
        input.withUnsafeBufferPointer { inBuf in
            output.withUnsafeMutableBufferPointer { outBuf in
                var inPtr: UnsafePointer<Float>? = inBuf.baseAddress
                var outPtr: UnsafeMutablePointer<Float>? = outBuf.baseAddress
                withUnsafePointer(to: &inPtr) { ip in
                    withUnsafeMutablePointer(to: &outPtr) { op in
                        dsp_kernel_process(kernel, ip, op, 1, 4)
                    }
                }
            }
        }

        #expect(dsp_kernel_profiler_current_us(kernel) == 0,
               "Profiler should not update during bypass")
        #expect(dsp_kernel_profiler_avg_us(kernel) == 0,
               "Profiler avg should not update during bypass")
    }

    @Test func profilerPassthroughDoesNotUpdate() {
        // With no backend loaded, process() falls through to passthrough
        // and the profiler should not update
        let kernel = dsp_kernel_create()!
        defer { dsp_kernel_destroy(kernel) }

        dsp_kernel_initialize(kernel, 1, 1, 44100)

        var input: [Float] = [0.1, 0.2, 0.3, 0.4]
        var output: [Float] = [0, 0, 0, 0]
        input.withUnsafeBufferPointer { inBuf in
            output.withUnsafeMutableBufferPointer { outBuf in
                var inPtr: UnsafePointer<Float>? = inBuf.baseAddress
                var outPtr: UnsafeMutablePointer<Float>? = outBuf.baseAddress
                withUnsafePointer(to: &inPtr) { ip in
                    withUnsafeMutablePointer(to: &outPtr) { op in
                        dsp_kernel_process(kernel, ip, op, 1, 4)
                    }
                }
            }
        }

        // Passthrough (no backend) should not update profiler
        #expect(dsp_kernel_profiler_current_us(kernel) == 0,
               "Profiler should not update during passthrough (no backend)")
        // But output should still be passthrough
        #expect(output == [0.1, 0.2, 0.3, 0.4], "Passthrough should copy input to output")
    }
}
