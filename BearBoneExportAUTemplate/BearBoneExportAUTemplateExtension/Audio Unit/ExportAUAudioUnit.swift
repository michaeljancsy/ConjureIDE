//
//  ExportAUAudioUnit.swift
//  BearBoneExportAUTemplateExtension
//
//  Minimal AUAudioUnit that loads a single WASM preset from its bundle Resources.
//  This is the template AU for BearBone's "Export Preset as Standalone AUv3" feature.
//

import AVFoundation
import os.log

private let pluginLog = Logger(subsystem: "com.BearBone-user.ExportTemplate", category: "DSP")

public class ExportAUAudioUnit: AUAudioUnit, @unchecked Sendable {
    // Rust DSP kernel (opaque pointer)
    private var kernel: DSPKernelRef!

    // Runtime configuration loaded from bundle
    private var config: RuntimeConfig?

    // Audio busses
    private var _inputBus: AUAudioUnitBus!
    private var _outputBus: AUAudioUnitBus!
    private var _inputBusses: AUAudioUnitBusArray!
    private var _outputBusses: AUAudioUnitBusArray!

    // Input buffer management
    private var inputPCMBuffer: AVAudioPCMBuffer?
    private var originalAudioBufferList: UnsafePointer<AudioBufferList>?
    private var mutableAudioBufferList: UnsafeMutablePointer<AudioBufferList>?
    private var _maxFrames: AUAudioFrameCount = 0

    @objc override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions) throws {
        kernel = dsp_kernel_create()

        // Default to mono; host will negotiate the actual channel count.
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        try super.init(componentDescription: componentDescription, options: options)

        _inputBus = try AUAudioUnitBus(format: format)
        _inputBus.maximumChannelCount = 2

        _outputBus = try AUAudioUnitBus(format: format)
        _outputBus.maximumChannelCount = 2

        _inputBusses = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [_inputBus])
        _outputBusses = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [_outputBus])

        // Load runtime config
        let bundle = Bundle(for: type(of: self))
        config = RuntimeConfig.load(from: bundle)

        buildParameterTree()

        // Exported AUs run freely — no demo timer
        dsp_kernel_set_licensed(kernel, true)

        // Load the WASM preset from bundle
        loadPresetFromBundle()
    }

    // MARK: - Parameter Tree

    private func buildParameterTree() {
        let count = config?.effectiveParamCount ?? 8
        var params: [AUParameter] = []
        for i in 0..<count {
            let name = config?.paramLabel(at: i) ?? "Param \(i + 1)"
            let param = AUParameterTree.createParameter(
                withIdentifier: "param\(i)",
                name: name,
                address: AUParameterAddress(i),
                min: 0.0,
                max: 1.0,
                unit: .generic,
                unitName: nil,
                flags: [.flag_IsReadable, .flag_IsWritable],
                valueStrings: nil,
                dependentParameters: nil
            )
            param.value = 0.0
            params.append(param)
        }
        let tree = AUParameterTree.createTree(withChildren: params)
        let kernelRef = self.kernel!
        tree.implementorValueObserver = { param, value in
            dsp_kernel_set_parameter(kernelRef, param.address, value)
        }
        tree.implementorValueProvider = { param in
            return dsp_kernel_get_parameter(kernelRef, param.address)
        }
        tree.implementorStringFromValueCallback = { param, valuePtr in
            let value = valuePtr?.pointee ?? param.value
            return String(format: "%.3f", value)
        }
        self.parameterTree = tree
    }

    // MARK: - Preset Loading

    private func loadPresetFromBundle() {
        let bundle = Bundle(for: type(of: self))
        guard let wasmURL = bundle.url(forResource: "preset", withExtension: "wasm"),
              let wasmData = try? Data(contentsOf: wasmURL) else {
            pluginLog.error("preset.wasm not found in bundle")
            return
        }

        let success = wasmData.withUnsafeBytes { rawBuffer -> Bool in
            guard let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return false
            }
            return dsp_kernel_load_wasm(kernel, ptr, UInt32(wasmData.count))
        }

        if success {
            pluginLog.info("WASM preset loaded successfully")
            // Warm-start: run process() so any first-call setup happens before real audio
            let warmupTime = dsp_kernel_benchmark_process(kernel)
            if warmupTime >= 0 {
                pluginLog.info("Warm-up complete: \(warmupTime * 1000, privacy: .public)ms")
            }
        } else {
            if let errPtr = dsp_kernel_last_error(kernel) {
                let errMsg = String(cString: errPtr)
                pluginLog.error("Failed to load WASM: \(errMsg, privacy: .public)")
            } else {
                pluginLog.error("Failed to load WASM preset")
            }
        }
    }

    // MARK: - Lifecycle

    deinit {
        if let kernel = kernel {
            dsp_kernel_destroy(kernel)
        }
    }

    public override var inputBusses: AUAudioUnitBusArray {
        return _inputBusses
    }

    public override var outputBusses: AUAudioUnitBusArray {
        return _outputBusses
    }

    public override var channelCapabilities: [NSNumber] {
        return [NSNumber(value: 1), NSNumber(value: 1),
                NSNumber(value: 2), NSNumber(value: 2)]
    }

    public override var maximumFramesToRender: AUAudioFrameCount {
        get { dsp_kernel_get_max_frames(kernel) }
        set { dsp_kernel_set_max_frames(kernel, newValue) }
    }

    public override var shouldBypassEffect: Bool {
        get { dsp_kernel_is_bypassed(kernel) }
        set { dsp_kernel_set_bypassed(kernel, newValue) }
    }

    // MARK: - Render Resources

    public override func allocateRenderResources() throws {
        let inputChannelCount = inputBusses[0].format.channelCount
        let outputChannelCount = outputBusses[0].format.channelCount

        if outputChannelCount != inputChannelCount {
            setRenderResourcesAllocated(false)
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FailedInitialization), userInfo: nil)
        }

        _maxFrames = self.maximumFramesToRender
        inputPCMBuffer = AVAudioPCMBuffer(pcmFormat: _inputBus.format, frameCapacity: _maxFrames)
        originalAudioBufferList = inputPCMBuffer?.audioBufferList
        mutableAudioBufferList = inputPCMBuffer?.mutableAudioBufferList

        dsp_kernel_initialize(kernel, Int32(inputChannelCount), Int32(outputChannelCount), _outputBus.format.sampleRate)

        try super.allocateRenderResources()
    }

    public override func deallocateRenderResources() {
        dsp_kernel_deinitialize(kernel)
        inputPCMBuffer = nil
        originalAudioBufferList = nil
        mutableAudioBufferList = nil
        super.deallocateRenderResources()
    }

    // MARK: - Rendering

    public override var internalRenderBlock: AUInternalRenderBlock {
        let kernel = self.kernel!
        let unmanagedSelf = Unmanaged.passUnretained(self)

        return { actionFlags, timestamp, frameCount, outputBusNumber,
                 outputData, realtimeEventListHead, pullInputBlock in

            let au = unmanagedSelf.takeUnretainedValue()
            guard let originalABL = au.originalAudioBufferList,
                  let mutableABL = au.mutableAudioBufferList else {
                return kAudioUnitErr_Uninitialized
            }
            let maxFrames = au._maxFrames

            guard frameCount <= dsp_kernel_get_max_frames(kernel) else {
                return kAudioUnitErr_TooManyFramesToProcess
            }

            guard let pullInputBlock = pullInputBlock else {
                return kAudioUnitErr_NoConnection
            }

            // Prepare input buffer list
            let byteSize = min(frameCount, maxFrames) * UInt32(MemoryLayout<Float>.size)
            let mutableBufList = UnsafeMutableAudioBufferListPointer(mutableABL)
            let origBufList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: originalABL))
            mutableABL.pointee.mNumberBuffers = originalABL.pointee.mNumberBuffers
            for i in 0..<origBufList.count {
                mutableBufList[i].mNumberChannels = origBufList[i].mNumberChannels
                mutableBufList[i].mData = origBufList[i].mData
                mutableBufList[i].mDataByteSize = byteSize
            }

            var pullFlags = AudioUnitRenderActionFlags(rawValue: 0)
            let err = pullInputBlock(&pullFlags, timestamp, frameCount, 0, mutableABL)
            guard err == noErr else { return err }

            let inABL = UnsafeMutableAudioBufferListPointer(mutableABL)
            let outABL = UnsafeMutableAudioBufferListPointer(outputData)

            // If passed null output buffer pointers, process in-place.
            for i in 0..<outABL.count {
                if outABL[i].mData == nil {
                    outABL[i].mData = inABL[i].mData
                }
            }

            // Process with events
            let channelCount = UInt32(inABL.count)
            var now = AUEventSampleTime(timestamp.pointee.mSampleTime)
            var framesRemaining = frameCount
            var nextEvent = realtimeEventListHead

            while framesRemaining > 0 {
                if nextEvent == nil {
                    let frameOffset = frameCount - framesRemaining
                    Self.callKernelProcess(kernel: kernel, inABL: inABL, outABL: outABL,
                                           channelCount: channelCount, frameOffset: frameOffset,
                                           frameCount: framesRemaining)
                    return noErr
                }

                let headEventTime = nextEvent!.pointee.head.eventSampleTime
                let framesThisSegment = UInt32(max(0, headEventTime - now))

                if framesThisSegment > 0 {
                    let frameOffset = frameCount - framesRemaining
                    Self.callKernelProcess(kernel: kernel, inABL: inABL, outABL: outABL,
                                           channelCount: channelCount, frameOffset: frameOffset,
                                           frameCount: framesThisSegment)
                    framesRemaining -= framesThisSegment
                    now += AUEventSampleTime(framesThisSegment)
                }

                nextEvent = Self.performAllSimultaneousEvents(kernel: kernel, now: now, event: nextEvent!)
            }

            return noErr
        }
    }

    private static func callKernelProcess(
        kernel: DSPKernelRef,
        inABL: UnsafeMutableAudioBufferListPointer,
        outABL: UnsafeMutableAudioBufferListPointer,
        channelCount: UInt32,
        frameOffset: UInt32,
        frameCount: UInt32
    ) {
        let count = Int(channelCount)

        var inputPtrs = [UnsafePointer<Float>?]()
        inputPtrs.reserveCapacity(count)
        var outputPtrs = [UnsafeMutablePointer<Float>?]()
        outputPtrs.reserveCapacity(count)

        for ch in 0..<count {
            let baseIn = inABL[ch].mData!.assumingMemoryBound(to: Float.self)
            inputPtrs.append(UnsafePointer(baseIn.advanced(by: Int(frameOffset))))

            let baseOut = outABL[ch].mData!.assumingMemoryBound(to: Float.self)
            outputPtrs.append(baseOut.advanced(by: Int(frameOffset)))
        }

        inputPtrs.withUnsafeBufferPointer { inBuf in
            outputPtrs.withUnsafeBufferPointer { outBuf in
                dsp_kernel_process(kernel, inBuf.baseAddress!, outBuf.baseAddress!, channelCount, frameCount)
            }
        }
    }

    private static func performAllSimultaneousEvents(
        kernel: DSPKernelRef,
        now: AUEventSampleTime,
        event: UnsafePointer<AURenderEvent>
    ) -> UnsafePointer<AURenderEvent>? {
        var current: UnsafePointer<AURenderEvent>? = event
        repeat {
            guard let evt = current else { break }

            if evt.pointee.head.eventType == .parameter {
                let paramEvent = evt.pointee.parameter
                dsp_kernel_set_parameter(kernel, paramEvent.parameterAddress, paramEvent.value)
            } else if evt.pointee.head.eventType == .parameterRamp {
                let paramEvent = evt.pointee.parameter
                dsp_kernel_set_parameter(kernel, paramEvent.parameterAddress, paramEvent.value)
            }

            if let next = evt.pointee.head.next {
                current = UnsafeRawPointer(next).assumingMemoryBound(to: AURenderEvent.self)
            } else {
                current = nil
            }
        } while current != nil && current!.pointee.head.eventSampleTime <= now
        return current
    }
}
