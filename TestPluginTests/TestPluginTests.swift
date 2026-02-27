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

    private static func instantiateAU() async throws -> (AVAudioUnit, AUAudioUnit) {
        let avAudioUnit = try await AVAudioUnit.instantiate(
            with: componentDescription,
            options: .loadInProcess
        )
        return (avAudioUnit, avAudioUnit.auAudioUnit)
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

        // Verify both channels have data (passthrough or processed)
        let outL = outputBuffer.floatChannelData![0]
        let outR = outputBuffer.floatChannelData![1]
        let valL = outL[1]
        let valR = outR[1]
        let isPassthroughL = abs(valL - inputL[1]) < 1e-6
        let isHalfGainL = abs(valL - inputL[1] * 0.5) < 1e-6
        #expect(isPassthroughL || isHalfGainL,
               "Left channel should be passthrough or 0.5x gain")

        let isPassthroughR = abs(valR - inputR[1]) < 1e-6
        let isHalfGainR = abs(valR - inputR[1] * 0.5) < 1e-6
        #expect(isPassthroughR || isHalfGainR,
               "Right channel should be passthrough or 0.5x gain")

        au.deallocateRenderResources()
    }

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
}
