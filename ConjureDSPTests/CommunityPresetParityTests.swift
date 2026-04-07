//
//  CommunityPresetParityTests.swift
//  ConjureDSPTests
//
//  Compares Python and Rust community preset outputs to verify they produce
//  identical results for the same input signal.
//  Uses the dsp_kernel C FFI directly — no AU instantiation needed.
//

import Testing
import Foundation

@Suite(.serialized)
struct CommunityPresetParityTests {

    // MARK: - Constants

    private static let sampleRate: Double = 44100
    private static let channels: Int = 2
    private static let chunkSize: Int = 512
    private static let durationSeconds: Double = 1.0
    // 1e-4 ≈ -80 dB — well below audible. Allows for minor differences
    // between WASM's embedded libm and the native platform's libm (sin, exp,
    // etc.) which can accumulate through feedback loops.
    private static let tolerance: Float = 1e-4

    // MARK: - Test Signal Generation

    private static func generateSineSignal() -> ([Float], [Float]) {
        let totalSamples = Int(sampleRate * durationSeconds)
        var signal = [Float](repeating: 0, count: totalSamples)
        let freq: Double = 440.0
        let twoPi = 2.0 * Double.pi

        for i in 0..<totalSamples {
            let t = Double(i) / sampleRate
            let sine = Float(sin(twoPi * freq * t))
            let window = Float(0.5 * (1.0 - cos(twoPi * Double(i) / Double(totalSamples))))
            signal[i] = sine * window
        }
        return (signal, signal)
    }

    private static func generateNoiseSignal() -> ([Float], [Float]) {
        let totalSamples = Int(sampleRate * durationSeconds)
        var signal = [Float](repeating: 0, count: totalSamples)
        let twoPi = 2.0 * Double.pi
        var seed: UInt32 = 12345

        for i in 0..<totalSamples {
            seed = seed &* 1664525 &+ 1013904223
            let noise = Float(seed) / Float(UInt32.max) * 2.0 - 1.0
            let window = Float(0.5 * (1.0 - cos(twoPi * Double(i) / Double(totalSamples))))
            signal[i] = noise * window
        }
        return (signal, signal)
    }

    // MARK: - Error Type

    private struct TestError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    // MARK: - Path Helpers

    private static var communityPresetsURL: URL {
        get throws {
            // Navigate from the test bundle to the repo root's community-presets/
            // Test bundle is at DerivedData/.../Build/Products/Debug/ConjureDSP.app/Contents/XCTests/ConjureDSPTests.xctest
            // Repo root can be found by looking for community-presets/ relative to the source
            let sourceFile = URL(fileURLWithPath: #file)
            let repoRoot = sourceFile
                .deletingLastPathComponent()  // ConjureDSPTests/
                .deletingLastPathComponent()  // repo root
            let presetsURL = repoRoot.appendingPathComponent("community-presets")
            guard FileManager.default.fileExists(atPath: presetsURL.path) else {
                throw TestError("community-presets not found at \(presetsURL.path)")
            }
            return presetsURL
        }
    }

    private static var extensionResourcesURL: URL {
        get throws {
            guard let plugInsURL = Bundle.main.builtInPlugInsURL else {
                throw TestError("Bundle.main.builtInPlugInsURL is nil")
            }
            let resourcesURL = plugInsURL
                .appendingPathComponent("ConjureDSPExtension.appex")
                .appendingPathComponent("Contents/Resources")
            guard FileManager.default.fileExists(atPath: resourcesURL.path) else {
                throw TestError("Extension resources not found at \(resourcesURL.path)")
            }
            return resourcesURL
        }
    }

    private static var pythonHome: String {
        get throws {
            let path = try extensionResourcesURL.appendingPathComponent("python-dist").path
            guard FileManager.default.fileExists(atPath: path) else {
                throw TestError("python-dist not found at \(path)")
            }
            return path
        }
    }

    private static var rustcURL: URL {
        get throws {
            let url = try extensionResourcesURL
                .appendingPathComponent("rustc-dist/bin/rustc")
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw TestError("rustc not found at \(url.path)")
            }
            return url
        }
    }

    private static var rustcSysroot: URL {
        get throws {
            try extensionResourcesURL.appendingPathComponent("rustc-dist")
        }
    }

    // MARK: - Preset Discovery

    static let presetNames: [String] = {
        guard let presetsPath = try? communityPresetsURL else { return [] }

        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: presetsPath.path) else { return [] }

        let pythonNames = Set(files
            .filter { $0.hasSuffix(".py") }
            .map { String($0.dropLast(".py".count)) })

        let rustNames = Set(files
            .filter { $0.hasSuffix(".rs") }
            .map { String($0.dropLast(".rs".count)) })

        return pythonNames.intersection(rustNames).sorted()
    }()

    // MARK: - FFI Render Helper

    private static func renderSignal(
        kernel: DSPKernelRef,
        inputL: [Float],
        inputR: [Float]
    ) -> ([Float], [Float]) {
        let totalSamples = inputL.count
        var outputL = [Float](repeating: 0, count: totalSamples)
        var outputR = [Float](repeating: 0, count: totalSamples)

        var offset = 0
        while offset < totalSamples {
            let remaining = totalSamples - offset
            let frameCount = min(remaining, chunkSize)

            inputL.withUnsafeBufferPointer { inLBuf in
                inputR.withUnsafeBufferPointer { inRBuf in
                    outputL.withUnsafeMutableBufferPointer { outLBuf in
                        outputR.withUnsafeMutableBufferPointer { outRBuf in
                            var inputPtrs: [UnsafePointer<Float>?] = [
                                inLBuf.baseAddress! + offset,
                                inRBuf.baseAddress! + offset
                            ]
                            var outputPtrs: [UnsafeMutablePointer<Float>?] = [
                                outLBuf.baseAddress! + offset,
                                outRBuf.baseAddress! + offset
                            ]
                            inputPtrs.withUnsafeBufferPointer { inPtrs in
                                outputPtrs.withUnsafeMutableBufferPointer { outPtrs in
                                    dsp_kernel_process(
                                        kernel,
                                        inPtrs.baseAddress!,
                                        outPtrs.baseAddress!,
                                        UInt32(channels),
                                        UInt32(frameCount)
                                    )
                                }
                            }
                        }
                    }
                }
            }

            offset += frameCount
        }

        return (outputL, outputR)
    }

    // MARK: - WASM Compilation

    private static func compileToWasm(source: String) throws -> Data {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("conjuredsp-community-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let inputFile = tempDir.appendingPathComponent("dsp.rs")
        let outputFile = tempDir.appendingPathComponent("dsp.wasm")
        try source.write(to: inputFile, atomically: true, encoding: .utf8)

        let rustc = try rustcURL
        let sysroot = try rustcSysroot

        let process = Process()
        process.executableURL = rustc
        var args = [
            "--sysroot", sysroot.path,
            "--target", "wasm32-wasip1",
            "--edition", "2021",
            "-C", "opt-level=2",
            "--crate-type", "cdylib",
            "-o", outputFile.path,
            inputFile.path,
        ]

        // Link conjuredsp rlib if available
        let rlibPath = sysroot.appendingPathComponent("lib/libconjuredsp.rlib").path
        if FileManager.default.fileExists(atPath: rlibPath) {
            args = ["--extern", "conjuredsp=\(rlibPath)"] + args
        }

        process.arguments = args

        var env = ProcessInfo.processInfo.environment
        env["DYLD_LIBRARY_PATH"] = sysroot.appendingPathComponent("lib").path
        process.environment = env

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: stderrData, encoding: .utf8) ?? "Unknown error"
            throw TestError("rustc failed for preset: \(stderr)")
        }

        return try Data(contentsOf: outputFile)
    }

    // MARK: - Kernel Helpers

    private static func renderWithPython(
        presetName: String,
        inputL: [Float],
        inputR: [Float]
    ) throws -> ([Float], [Float]) {
        let kernel = dsp_kernel_create()!
        defer { dsp_kernel_destroy(kernel) }

        dsp_kernel_set_licensed(kernel, true)
        dsp_kernel_initialize(kernel, Int32(channels), Int32(channels), sampleRate)
        dsp_kernel_set_max_frames(kernel, UInt32(chunkSize))

        let presetsURL = try communityPresetsURL
        let presetURL = presetsURL.appendingPathComponent("\(presetName).py")
        let source = try String(contentsOf: presetURL, encoding: .utf8)

        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(presetName)_\(UUID().uuidString).py")
        try source.write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let home = try pythonHome
        let loaded = dsp_kernel_load_script(kernel, home, tempFile.path)
        guard loaded else {
            let errPtr = dsp_kernel_last_error(kernel)
            let msg = errPtr != nil ? String(cString: errPtr!) : "Unknown error"
            throw TestError("Failed to load Python preset \(presetName): \(msg)")
        }

        // Set transport so BPM-synced presets get consistent tempo data
        dsp_kernel_set_transport(kernel, 120.0, 0.0, true, 4, 4, 0.0)

        // Set all params to 0.5 (normalized) for consistent state
        for i in 0..<16 {
            dsp_kernel_set_parameter(kernel, UInt64(i), 0.5)
        }

        return renderSignal(kernel: kernel, inputL: inputL, inputR: inputR)
    }

    private static func renderWithRust(
        presetName: String,
        inputL: [Float],
        inputR: [Float]
    ) throws -> ([Float], [Float]) {
        let kernel = dsp_kernel_create()!
        defer { dsp_kernel_destroy(kernel) }

        dsp_kernel_set_licensed(kernel, true)
        dsp_kernel_initialize(kernel, Int32(channels), Int32(channels), sampleRate)
        dsp_kernel_set_max_frames(kernel, UInt32(chunkSize))

        let presetsURL = try communityPresetsURL
        let presetURL = presetsURL.appendingPathComponent("\(presetName).rs")
        let source = try String(contentsOf: presetURL, encoding: .utf8)
        let wasmBytes = try compileToWasm(source: source)

        let loaded = wasmBytes.withUnsafeBytes { buf in
            dsp_kernel_load_wasm(kernel, buf.baseAddress!.assumingMemoryBound(to: UInt8.self), UInt32(buf.count))
        }
        guard loaded else {
            let errPtr = dsp_kernel_last_error(kernel)
            let msg = errPtr != nil ? String(cString: errPtr!) : "Unknown error"
            throw TestError("Failed to load WASM for preset \(presetName): \(msg)")
        }

        // Set transport so BPM-synced presets get consistent tempo data
        dsp_kernel_set_transport(kernel, 120.0, 0.0, true, 4, 4, 0.0)

        // Set all params to 0.5 (normalized) to match the Python test setup
        for i in 0..<16 {
            dsp_kernel_set_parameter(kernel, UInt64(i), 0.5)
        }

        return renderSignal(kernel: kernel, inputL: inputL, inputR: inputR)
    }

    // MARK: - Comparison

    private static func compareOutputs(
        pythonL: [Float], pythonR: [Float],
        rustL: [Float], rustR: [Float],
        presetName: String,
        signalName: String
    ) -> String? {
        guard pythonL.count == rustL.count, pythonR.count == rustR.count else {
            return "\(presetName) [\(signalName)]: length mismatch (Python: \(pythonL.count), Rust: \(rustL.count))"
        }

        var maxErrorL: Float = 0
        var maxErrorR: Float = 0
        var worstIndexL = 0
        var worstIndexR = 0

        for i in 0..<pythonL.count {
            let errL = abs(pythonL[i] - rustL[i])
            let errR = abs(pythonR[i] - rustR[i])
            if errL > maxErrorL { maxErrorL = errL; worstIndexL = i }
            if errR > maxErrorR { maxErrorR = errR; worstIndexR = i }
        }

        let maxError = max(maxErrorL, maxErrorR)
        if maxError > tolerance {
            let ch = maxErrorL >= maxErrorR ? "L" : "R"
            let idx = maxErrorL >= maxErrorR ? worstIndexL : worstIndexR
            let err = maxErrorL >= maxErrorR ? maxErrorL : maxErrorR
            let pyVal = maxErrorL >= maxErrorR ? pythonL[idx] : pythonR[idx]
            let rsVal = maxErrorL >= maxErrorR ? rustL[idx] : rustR[idx]
            return "\(presetName) [\(signalName)]: max error \(err) at \(ch)[\(idx)] (Python=\(pyVal), Rust=\(rsVal))"
        }
        return nil
    }

    // MARK: - Tests

    @Test("Community presets produce matching Python/Rust output for A440 sine")
    func communityPresetsParitySine() throws {
        let (inputL, inputR) = Self.generateSineSignal()
        var failures: [String] = []

        for presetName in Self.presetNames {
            let (pyOutL, pyOutR) = try Self.renderWithPython(
                presetName: presetName, inputL: inputL, inputR: inputR)
            let (rsOutL, rsOutR) = try Self.renderWithRust(
                presetName: presetName, inputL: inputL, inputR: inputR)

            if let error = Self.compareOutputs(
                pythonL: pyOutL, pythonR: pyOutR,
                rustL: rsOutL, rustR: rsOutR,
                presetName: presetName,
                signalName: "A440 sine"
            ) {
                failures.append(error)
            }
        }

        #expect(failures.isEmpty, "Parity failures:\n\(failures.joined(separator: "\n"))")
    }

    @Test("Community presets produce matching Python/Rust output for white noise")
    func communityPresetsParityNoise() throws {
        let (inputL, inputR) = Self.generateNoiseSignal()
        var failures: [String] = []

        for presetName in Self.presetNames {
            let (pyOutL, pyOutR) = try Self.renderWithPython(
                presetName: presetName, inputL: inputL, inputR: inputR)
            let (rsOutL, rsOutR) = try Self.renderWithRust(
                presetName: presetName, inputL: inputL, inputR: inputR)

            if let error = Self.compareOutputs(
                pythonL: pyOutL, pythonR: pyOutR,
                rustL: rsOutL, rustR: rsOutR,
                presetName: presetName,
                signalName: "white noise"
            ) {
                failures.append(error)
            }
        }

        #expect(failures.isEmpty, "Parity failures:\n\(failures.joined(separator: "\n"))")
    }
}
