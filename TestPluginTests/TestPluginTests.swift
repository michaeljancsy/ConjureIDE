//
//  TestPluginTests.swift
//  TestPluginTests
//
//  Created by Michael Jancsy on 2/25/26.
//

import Testing
import AVFoundation
import AudioToolbox

struct TestPluginTests {

    // MARK: - Helpers

    private static var componentDescription: AudioComponentDescription {
        AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: fourCharCode("0001"),
            componentManufacturer: fourCharCode("A000"),
            componentFlags: 0,
            componentFlagsMask: 0
        )
    }

    private static func fourCharCode(_ string: String) -> FourCharCode {
        var code: FourCharCode = 0
        for byte in string.utf8 {
            code = code << 8 + FourCharCode(byte)
        }
        return code
    }

    // MARK: - Component Discovery

    @Test func audioUnitComponentIsRegistered() async throws {
        let components = AVAudioUnitComponentManager.shared()
            .components(matching: Self.componentDescription)
        #expect(!components.isEmpty, "AU component should be registered with the system")
    }

    // MARK: - AU Instantiation

    @Test func audioUnitCanBeInstantiated() async throws {
        let avAudioUnit = try await AVAudioUnit.instantiate(
            with: Self.componentDescription,
            options: .loadInProcess
        )
        let au = avAudioUnit.auAudioUnit
        #expect(au.componentDescription.componentType == kAudioUnitType_Effect)
        #expect(au.componentDescription.componentManufacturer == Self.fourCharCode("A000"))
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
}
