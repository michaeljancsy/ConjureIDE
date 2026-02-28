//
//  TestPluginExtensionAudioUnit.swift
//  TestPluginExtension
//
//  Created by Michael Jancsy on 2/25/26.
//

import AVFoundation
import os.log

private let pluginLog = Logger(subsystem: "com.MichaelJancsy.TestPlugin", category: "DSP")

public class TestPluginExtensionAudioUnit: AUAudioUnit, @unchecked Sendable
{
	// Rust DSP kernel (opaque pointer)
	private var kernel: DSPKernelRef!

	// Cached path to bundled Python runtime for script reloads
	private var pythonHome: String?

	// Audio busses
	private var _inputBus: AUAudioUnitBus!
	private var _outputBus: AUAudioUnitBus!
	private var _inputBusses: AUAudioUnitBusArray!
	private var _outputBusses: AUAudioUnitBusArray!

	// Input buffer management (replaces C++ BufferedInputBus)
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

		// Load the bundled Python DSP script
		loadPythonScript()
	}

	private func loadPythonScript() {
		let bundle = Bundle(for: type(of: self))

		// Python home: the bundled Python standard library root
		// The bundle copies python-dist contents into Resources/python-dist/
		guard let pythonHome = bundle.path(forResource: "python-dist", ofType: nil) else {
			pluginLog.error("Bundled Python distribution not found in bundle, using Rust fallback DSP")
			return
		}
		self.pythonHome = pythonHome

		guard let scriptPath = bundle.path(forResource: "process", ofType: "py") else {
			pluginLog.error("process.py not found in bundle, using Rust fallback DSP")
			return
		}

		pluginLog.info("Loading Python script. pythonHome=\(pythonHome, privacy: .public) scriptPath=\(scriptPath, privacy: .public)")
		let success = dsp_kernel_load_script(kernel, pythonHome, scriptPath)
		if success {
			pluginLog.info("Python DSP script loaded successfully")
		} else {
			if let errPtr = dsp_kernel_last_error(kernel) {
				let errMsg = String(cString: errPtr)
				pluginLog.error("Failed to load Python DSP script: \(errMsg, privacy: .public)")
			} else {
				pluginLog.error("Failed to load Python DSP script (no error details), using Rust fallback DSP")
			}
		}
	}

	/// Hot-reload a Python DSP script from source code.
	/// Writes the source to a temp file and calls dsp_kernel_load_script.
	/// On success, benchmarks the process function and returns timing info.
	public func reloadScript(source: String) -> (success: Bool, error: String?, processTimeMs: Double?, budgetMs: Double?) {
		guard let pythonHome = self.pythonHome else {
			return (false, "Python runtime not available", nil, nil)
		}

		let tempDir = FileManager.default.temporaryDirectory
		let tempFile = tempDir.appendingPathComponent("process_\(UUID().uuidString).py")

		do {
			try source.write(to: tempFile, atomically: true, encoding: .utf8)
		} catch {
			return (false, "Failed to write temp file: \(error.localizedDescription)", nil, nil)
		}

		defer {
			try? FileManager.default.removeItem(at: tempFile)
		}

		let success = dsp_kernel_load_script(kernel, pythonHome, tempFile.path)

		if success {
			pluginLog.info("Python DSP script reloaded successfully")

			// Benchmark the process function
			let benchmarkSecs = dsp_kernel_benchmark_process(kernel)
			var processTimeMs: Double? = nil
			var budgetMs: Double? = nil

			if benchmarkSecs >= 0 {
				processTimeMs = benchmarkSecs * 1000.0
				let sampleRate = _outputBus.format.sampleRate
				let maxFrames = Double(dsp_kernel_get_max_frames(kernel))
				budgetMs = maxFrames / sampleRate * 1000.0
				pluginLog.info("Benchmark: \(processTimeMs!, privacy: .public)ms / \(budgetMs!, privacy: .public)ms budget")
			}

			return (true, nil, processTimeMs, budgetMs)
		} else {
			var errorMsg = "Unknown error"
			if let errPtr = dsp_kernel_last_error(kernel) {
				errorMsg = String(cString: errPtr)
			}
			pluginLog.error("Failed to reload Python DSP script: \(errorMsg, privacy: .public)")
			return (false, errorMsg, nil, nil)
		}
	}

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

		// Allocate input buffer (replaces BufferedInputBus.allocateRenderResources)
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

		// Capture self via Unmanaged to avoid ARC on the audio thread.
		// Buffer list pointers are nil until allocateRenderResources() is called,
		// but the framework may read this property before that.
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

			// Pull input (replaces BufferedInputBus.pullInput)
			guard let pullInputBlock = pullInputBlock else {
				return kAudioUnitErr_NoConnection
			}

			// Prepare input buffer list (replaces BufferedInputBus.prepareInputBufferList)
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

			// If passed null output buffer pointers, process in-place in the input buffer.
			for i in 0..<outABL.count {
				if outABL[i].mData == nil {
					outABL[i].mData = inABL[i].mData
				}
			}

			// Process with events (replaces AUProcessHelper.processWithEvents)
			let channelCount = UInt32(inABL.count)
			var now = AUEventSampleTime(timestamp.pointee.mSampleTime)
			var framesRemaining = frameCount
			var nextEvent = realtimeEventListHead

			while framesRemaining > 0 {
				if nextEvent == nil {
					// Process remaining frames
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

				// Handle all simultaneous events
				nextEvent = Self.performAllSimultaneousEvents(kernel: kernel, now: now, event: nextEvent!)
			}

			return noErr
		}
	}

	/// Call the Rust kernel to process a segment of audio.
	private static func callKernelProcess(
		kernel: DSPKernelRef,
		inABL: UnsafeMutableAudioBufferListPointer,
		outABL: UnsafeMutableAudioBufferListPointer,
		channelCount: UInt32,
		frameOffset: UInt32,
		frameCount: UInt32
	) {
		let count = Int(channelCount)

		// Build contiguous arrays of channel buffer pointers (optional to match C import)
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

	/// Walk the event linked list, skipping all events at the current timestamp.
	private static func performAllSimultaneousEvents(
		kernel: DSPKernelRef,
		now: AUEventSampleTime,
		event: UnsafePointer<AURenderEvent>
	) -> UnsafePointer<AURenderEvent>? {
		var current: UnsafePointer<AURenderEvent>? = event
		repeat {
			guard let evt = current else { break }

			// Advance to next event
			if let next = evt.pointee.head.next {
				current = UnsafeRawPointer(next).assumingMemoryBound(to: AURenderEvent.self)
			} else {
				current = nil
			}
		} while current != nil && current!.pointee.head.eventSampleTime <= now
		return current
	}

}
