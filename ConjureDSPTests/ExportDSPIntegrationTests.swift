import Testing
import Foundation

// MARK: - Export DSP Integration Tests

/// Integration tests that export presets and verify audio processing via the Rust FFI.
/// Uses the same kernel-based approach as PresetComparisonTests — no AU instantiation needed.
@Suite(.serialized)
struct ExportDSPIntegrationTests {

    // MARK: - Constants

    private static let sampleRate: Double = 44100
    private static let channels: Int = 2
    private static let chunkSize: Int = 512
    private static let durationSeconds: Double = 0.5

    // MARK: - Error Type

    private struct TestError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    // MARK: - Path Helpers

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
            let url = try extensionResourcesURL.appendingPathComponent("rustc-dist/bin/rustc")
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

    /// Repo root derived from this source file's path.
    private static var repoRootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ConjureDSPTests/
            .deletingLastPathComponent()   // repo root
    }

    // MARK: - Signal Generation

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
            .appendingPathComponent("conjuredsp-export-test-\(UUID().uuidString)")
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
            throw TestError("rustc failed: \(stderr)")
        }

        return try Data(contentsOf: outputFile)
    }

    // MARK: - Template & Export Helpers

    private func findRealTemplate() -> URL? {
        let extensionBundle = Bundle.main.builtInPlugInsURL?
            .appendingPathComponent("ConjureDSPExtension.appex")
        if let extBundle = extensionBundle,
           let bundle = Bundle(url: extBundle),
           let templateURL = bundle.url(forResource: "ExportTemplate", withExtension: "zip") {
            return templateURL
        }
        return nil
    }

    private func makeTempOutputDir(testId: String) throws -> (URL, URL) {
        let fm = FileManager.default
        let outputDir = fm.temporaryDirectory
            .appendingPathComponent("ExportDSPTest_\(testId)")
        try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let registryURL = fm.temporaryDirectory
            .appendingPathComponent("ExportDSPReg_\(testId)")
            .appendingPathComponent("export-registry.json")
        return (outputDir, registryURL)
    }

    private func appexResourcesPath(in appURL: URL) -> URL {
        appURL
            .appendingPathComponent("Contents/PlugIns/ConjureDSPExportAUTemplateExtension.appex")
            .appendingPathComponent("Contents/Resources")
    }

    // MARK: - Integration Tests

    @Test("Export Rust passthrough preset and verify audio processing")
    func exportRustPresetAndVerifyAudio() throws {
        guard let templateURL = findRealTemplate() else {
            print("Skipping: ExportTemplate.zip not found")
            return
        }

        let testId = UUID().uuidString.prefix(8)
        let (outputDir, registryURL) = try makeTempOutputDir(testId: String(testId))
        defer {
            try? FileManager.default.removeItem(at: outputDir)
            try? FileManager.default.removeItem(at: registryURL.deletingLastPathComponent())
        }

        // 1. Read and compile Rust passthrough preset
        let resourcesURL = try Self.extensionResourcesURL
        let source = try String(contentsOf: resourcesURL.appendingPathComponent("presets/preset_passthrough_rust.cdp/process.rs"), encoding: .utf8)
        let wasmData = try Self.compileToWasm(source: source)

        // 2. Export
        let registry = ExportRegistry(registryURL: registryURL)
        let manager = ExportManager(registry: registry)
        let appURL = try manager.exportPreset(
            name: "ExportTest_Passthrough_\(testId)",
            source: source,
            wasmData: wasmData,
            language: .rust,
            templateURL: templateURL,
            outputDirectory: outputDir,
            skipSigning: true
        )

        // 3. Read exported WASM back from bundle
        let exportedWasm = try Data(contentsOf: appexResourcesPath(in: appURL).appendingPathComponent("preset.wasm"))
        #expect(exportedWasm == wasmData, "Exported WASM should match input")

        // 4. Load into fresh kernel and process audio
        let kernel = dsp_kernel_create()!
        defer { dsp_kernel_destroy(kernel) }
        dsp_kernel_set_licensed(kernel, true)
        dsp_kernel_initialize(kernel, Int32(Self.channels), Int32(Self.channels), Self.sampleRate)
        dsp_kernel_set_max_frames(kernel, UInt32(Self.chunkSize))

        let loaded = exportedWasm.withUnsafeBytes { buf in
            dsp_kernel_load_wasm(kernel, buf.baseAddress!.assumingMemoryBound(to: UInt8.self), UInt32(buf.count))
        }
        #expect(loaded, "WASM should load successfully into kernel")

        // 5. Process sine wave and verify passthrough
        let (inputL, inputR) = Self.generateSineSignal()
        let (outputL, outputR) = Self.renderSignal(kernel: kernel, inputL: inputL, inputR: inputR)

        var maxError: Float = 0
        for i in 0..<inputL.count {
            maxError = max(maxError, abs(outputL[i] - inputL[i]))
            maxError = max(maxError, abs(outputR[i] - inputR[i]))
        }
        #expect(maxError < 1e-6, "Passthrough output should match input (max error: \(maxError))")
    }

    @Test("Export Python passthrough preset and verify audio processing")
    func exportPythonPresetAndVerifyAudio() throws {
        guard let templateURL = findRealTemplate() else {
            print("Skipping: ExportTemplate.zip not found")
            return
        }

        let testId = UUID().uuidString.prefix(8)
        let (outputDir, registryURL) = try makeTempOutputDir(testId: String(testId))
        defer {
            try? FileManager.default.removeItem(at: outputDir)
            try? FileManager.default.removeItem(at: registryURL.deletingLastPathComponent())
        }

        // 1. Read Python passthrough preset
        let resourcesURL = try Self.extensionResourcesURL
        let source = try String(contentsOf: resourcesURL.appendingPathComponent("presets/preset_passthrough.cdp/process.py"), encoding: .utf8)

        // 2. Export
        let registry = ExportRegistry(registryURL: registryURL)
        let manager = ExportManager(registry: registry)
        let appURL = try manager.exportPreset(
            name: "ExportTest_PyPassthrough_\(testId)",
            source: source,
            wasmData: nil,
            language: .python,
            templateURL: templateURL,
            outputDirectory: outputDir,
            skipSigning: true
        )

        // 3. Read exported Python file back from bundle
        let exportedPy = try String(contentsOf: appexResourcesPath(in: appURL).appendingPathComponent("preset.py"), encoding: .utf8)
        #expect(exportedPy == source, "Exported Python should match input")

        // 4. Write to temp file and load into kernel
        let tempScript = FileManager.default.temporaryDirectory
            .appendingPathComponent("export_test_\(testId).py")
        try exportedPy.write(to: tempScript, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempScript) }

        let kernel = dsp_kernel_create()!
        defer { dsp_kernel_destroy(kernel) }
        dsp_kernel_set_licensed(kernel, true)
        dsp_kernel_initialize(kernel, Int32(Self.channels), Int32(Self.channels), Self.sampleRate)
        dsp_kernel_set_max_frames(kernel, UInt32(Self.chunkSize))

        let home = try Self.pythonHome
        let loaded = dsp_kernel_load_script(kernel, home, tempScript.path)
        #expect(loaded, "Python script should load successfully into kernel")

        // 5. Process sine wave and verify passthrough
        let (inputL, inputR) = Self.generateSineSignal()
        let (outputL, outputR) = Self.renderSignal(kernel: kernel, inputL: inputL, inputR: inputR)

        var maxError: Float = 0
        for i in 0..<inputL.count {
            maxError = max(maxError, abs(outputL[i] - inputL[i]))
            maxError = max(maxError, abs(outputR[i] - inputR[i]))
        }
        #expect(maxError < 1e-6, "Passthrough output should match input (max error: \(maxError))")
    }

    @Test("Export Rust gainpan preset and verify non-trivial DSP processing")
    func exportRustPresetWithDSPVerifyProcessing() throws {
        guard let templateURL = findRealTemplate() else {
            print("Skipping: ExportTemplate.zip not found")
            return
        }

        let testId = UUID().uuidString.prefix(8)
        let (outputDir, registryURL) = try makeTempOutputDir(testId: String(testId))
        defer {
            try? FileManager.default.removeItem(at: outputDir)
            try? FileManager.default.removeItem(at: registryURL.deletingLastPathComponent())
        }

        // 1. Read and compile Rust gainpan preset (has rich params)
        let resourcesURL = try Self.extensionResourcesURL
        let source = try String(contentsOf: resourcesURL.appendingPathComponent("presets/preset_gainpan_rust.cdp/process.rs"), encoding: .utf8)
        let wasmData = try Self.compileToWasm(source: source)

        // 2. Export with param metadata
        let metadata: [ParamMetadata] = [
            ParamMetadata(name: "Gain", key: "gain", min: -24, max: 12, default: 0, unit: "dB", curve: nil),
            ParamMetadata(name: "Pan", key: "pan", min: 0, max: 1, default: 0.5, unit: "", curve: nil),
        ]

        let registry = ExportRegistry(registryURL: registryURL)
        let manager = ExportManager(registry: registry)
        let appURL = try manager.exportPreset(
            name: "ExportTest_GainPan_\(testId)",
            source: source,
            wasmData: wasmData,
            language: .rust,
            templateURL: templateURL,
            outputDirectory: outputDir,
            skipSigning: true,
            paramMetadata: metadata
        )

        // 3. Load exported WASM into kernel
        let exportedWasm = try Data(contentsOf: appexResourcesPath(in: appURL).appendingPathComponent("preset.wasm"))

        let kernel = dsp_kernel_create()!
        defer { dsp_kernel_destroy(kernel) }
        dsp_kernel_set_licensed(kernel, true)
        dsp_kernel_initialize(kernel, Int32(Self.channels), Int32(Self.channels), Self.sampleRate)
        dsp_kernel_set_max_frames(kernel, UInt32(Self.chunkSize))

        let loaded = exportedWasm.withUnsafeBytes { buf in
            dsp_kernel_load_wasm(kernel, buf.baseAddress!.assumingMemoryBound(to: UInt8.self), UInt32(buf.count))
        }
        #expect(loaded, "WASM should load successfully")

        // 4. Set gain to minimum (-24 dB) by setting normalized param 0 to 0.0
        dsp_kernel_set_parameter(kernel, 0, 0.0)
        // Pan centered
        dsp_kernel_set_parameter(kernel, 1, 0.5)

        // 5. Process sine wave
        let (inputL, inputR) = Self.generateSineSignal()
        let (outputL, outputR) = Self.renderSignal(kernel: kernel, inputL: inputL, inputR: inputR)

        // 6. Verify output is attenuated (not passthrough)
        // At -24 dB, gain ≈ 0.063. Output amplitude should be ~6% of input.
        let inputPeak = inputL.map { abs($0) }.max() ?? 0
        let outputPeak = max(outputL.map { abs($0) }.max() ?? 0, outputR.map { abs($0) }.max() ?? 0)

        #expect(inputPeak > 0.1, "Input should have significant amplitude")
        #expect(outputPeak > 0, "Output should not be silent")
        #expect(outputPeak < inputPeak * 0.2, "Output should be significantly attenuated at -24dB (input peak: \(inputPeak), output peak: \(outputPeak))")
    }

    @Test("Export with paramMetadata and verify runtime-config.json round-trip")
    func exportWithParamMetadataVerifyRoundTrip() throws {
        guard let templateURL = findRealTemplate() else {
            print("Skipping: ExportTemplate.zip not found")
            return
        }

        let testId = UUID().uuidString.prefix(8)
        let (outputDir, registryURL) = try makeTempOutputDir(testId: String(testId))
        defer {
            try? FileManager.default.removeItem(at: outputDir)
            try? FileManager.default.removeItem(at: registryURL.deletingLastPathComponent())
        }

        let metadata: [ParamMetadata] = [
            ParamMetadata(name: "Cutoff", key: "cutoff", min: 20, max: 20000, default: 1000, unit: "Hz", curve: "log"),
            ParamMetadata(name: "Resonance", key: "resonance", min: 0, max: 1, default: 0.5, unit: "", curve: nil),
            ParamMetadata(name: "Mix", key: "mix", min: 0, max: 100, default: 100, unit: "%", curve: nil),
        ]

        // Use fake WASM (only testing config, not audio)
        let wasmData = Data([0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00])

        let registry = ExportRegistry(registryURL: registryURL)
        let manager = ExportManager(registry: registry)
        let appURL = try manager.exportPreset(
            name: "ExportTest_Metadata_\(testId)",
            source: "fn process() {}",
            wasmData: wasmData,
            language: .rust,
            templateURL: templateURL,
            outputDirectory: outputDir,
            skipSigning: true,
            paramMetadata: metadata
        )

        // Parse runtime-config.json
        let configURL = appexResourcesPath(in: appURL).appendingPathComponent("runtime-config.json")
        let configData = try Data(contentsOf: configURL)
        let config = try JSONSerialization.jsonObject(with: configData) as! [String: Any]

        // Verify required fields
        #expect(config["version"] as? Int == 1)
        #expect(config["language"] as? String == "rust")
        #expect((config["presetName"] as? String)?.contains("ExportTest_Metadata") == true)
        #expect(config["paramCount"] as? Int == 3)

        // Verify paramMetadata array
        let metaArray = try #require(config["paramMetadata"] as? [[String: Any]])
        #expect(metaArray.count == 3)

        #expect(metaArray[0]["name"] as? String == "Cutoff")
        #expect(metaArray[0]["key"] as? String == "cutoff")
        #expect(metaArray[0]["min"] as? Float == 20)
        #expect(metaArray[0]["max"] as? Float == 20000)
        #expect(metaArray[0]["default"] as? Float == 1000)
        #expect(metaArray[0]["unit"] as? String == "Hz")
        #expect(metaArray[0]["curve"] as? String == "log")

        #expect(metaArray[1]["name"] as? String == "Resonance")
        #expect(metaArray[1]["curve"] == nil, "Linear curve should be omitted")

        // Verify backward-compat paramNames
        let names = try #require(config["paramNames"] as? [String])
        #expect(names == ["Cutoff", "Resonance", "Mix"])
    }

    @Test("Export runtime-config.json contains all required fields for both languages")
    func exportRuntimeConfigRequiredFields() throws {
        guard let templateURL = findRealTemplate() else {
            print("Skipping: ExportTemplate.zip not found")
            return
        }

        let testId = UUID().uuidString.prefix(8)
        let (outputDir, registryURL) = try makeTempOutputDir(testId: String(testId))
        defer {
            try? FileManager.default.removeItem(at: outputDir)
            try? FileManager.default.removeItem(at: registryURL.deletingLastPathComponent())
        }

        let registry = ExportRegistry(registryURL: registryURL)
        let manager = ExportManager(registry: registry)

        // Export Rust preset
        let wasmData = Data([0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00])
        let rustURL = try manager.exportPreset(
            name: "ConfigTest_Rust_\(testId)",
            source: "fn process() {}",
            wasmData: wasmData,
            language: .rust,
            templateURL: templateURL,
            outputDirectory: outputDir,
            skipSigning: true
        )

        // Export Python preset
        let pyURL = try manager.exportPreset(
            name: "ConfigTest_Python_\(testId)",
            source: "def process(ctx): pass",
            wasmData: nil,
            language: .python,
            templateURL: templateURL,
            outputDirectory: outputDir,
            skipSigning: true
        )

        let requiredKeys = ["version", "language", "presetName", "exportDate", "paramCount"]

        for (url, lang) in [(rustURL, "rust"), (pyURL, "python")] {
            let configData = try Data(contentsOf: appexResourcesPath(in: url).appendingPathComponent("runtime-config.json"))
            let config = try JSONSerialization.jsonObject(with: configData) as! [String: Any]

            for key in requiredKeys {
                #expect(config[key] != nil, "\(lang) config missing required field '\(key)'")
            }
            #expect(config["language"] as? String == lang)
        }
    }

    @Test("Export with very long preset name")
    func exportWithVeryLongPresetName() throws {
        guard let templateURL = findRealTemplate() else {
            print("Skipping: ExportTemplate.zip not found")
            return
        }

        let testId = UUID().uuidString.prefix(8)
        let (outputDir, registryURL) = try makeTempOutputDir(testId: String(testId))
        defer {
            try? FileManager.default.removeItem(at: outputDir)
            try? FileManager.default.removeItem(at: registryURL.deletingLastPathComponent())
        }

        let longName = String(repeating: "A", count: 200) + "_\(testId)"
        let wasmData = Data([0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00])

        let registry = ExportRegistry(registryURL: registryURL)
        let manager = ExportManager(registry: registry)
        let appURL = try manager.exportPreset(
            name: longName,
            source: "fn process() {}",
            wasmData: wasmData,
            language: .rust,
            templateURL: templateURL,
            outputDirectory: outputDir,
            skipSigning: true
        )

        // Export should succeed
        #expect(FileManager.default.fileExists(atPath: appURL.path))

        // Verify runtime-config preserves full name
        let configData = try Data(contentsOf: appexResourcesPath(in: appURL).appendingPathComponent("runtime-config.json"))
        let config = try JSONSerialization.jsonObject(with: configData) as! [String: Any]
        #expect(config["presetName"] as? String == longName)

        // Verify plist contains the full name in AU display
        let extPlistURL = appURL
            .appendingPathComponent("Contents/PlugIns/ConjureDSPExportAUTemplateExtension.appex")
            .appendingPathComponent("Contents/Info.plist")
        let plistData = try Data(contentsOf: extPlistURL)
        let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as! [String: Any]
        let nsExt = plist["NSExtension"] as! [String: Any]
        let attrs = nsExt["NSExtensionAttributes"] as! [String: Any]
        let components = attrs["AudioComponents"] as! [[String: Any]]
        #expect(components[0]["name"] as? String == "ConjureDSP: \(longName)")
    }

    // MARK: - NAM Serialization Helper

    /// Serialize a .nam JSON file to the binary protocol used by `dsp_kernel_inject_nam_slot()`.
    /// This replicates the serialization in `ExportAUAudioUnit.injectEmbeddedNamModel()` exactly.
    private static func serializeNamFile(at url: URL) throws -> Data {
        let namData = try Data(contentsOf: url)
        let namJson = try JSONSerialization.jsonObject(with: namData) as! [String: Any]

        let architecture = namJson["architecture"] as! String
        let configObj = namJson["config"]!
        let weightsArray = namJson["weights"] as! [Double]

        let arch: UInt32 = architecture == "LSTM" ? 1 : 0
        let sampleRate = Float(
            (namJson["sample_rate"] as? Double)
            ?? (namJson["sample_rate"] as? Int).map(Double.init)
            ?? 48000.0
        )

        let configData = try JSONSerialization.data(withJSONObject: configObj)

        var binary = Data()
        var archLE = arch.littleEndian
        binary.append(Data(bytes: &archLE, count: 4))
        var srLE = sampleRate.bitPattern.littleEndian
        binary.append(Data(bytes: &srLE, count: 4))
        var configLen = UInt32(configData.count).littleEndian
        binary.append(Data(bytes: &configLen, count: 4))
        binary.append(configData)
        var weightCount = UInt32(weightsArray.count).littleEndian
        binary.append(Data(bytes: &weightCount, count: 4))
        for w in weightsArray {
            var f = Float(w).bitPattern.littleEndian
            binary.append(Data(bytes: &f, count: 4))
        }

        return binary
    }

    /// Helper to get the last kernel error as a Swift string.
    private static func kernelError(_ kernel: DSPKernelRef) -> String {
        if let ptr = dsp_kernel_last_error(kernel) {
            return String(cString: ptr)
        }
        return "(none)"
    }

    // MARK: - NAM Integration Tests

    @Test("NAM LSTM preset processes audio correctly (not static)")
    func namLstmPresetProducesCorrectAudio() throws {
        // 1. Compile NAM preset source to WASM
        let resourcesURL = try Self.extensionResourcesURL
        let source = try String(contentsOf: resourcesURL.appendingPathComponent("presets/preset_nam_rust.cdp/process.rs"), encoding: .utf8)
        let wasmData = try Self.compileToWasm(source: source)

        // 2. Create kernel and load WASM
        let kernel = dsp_kernel_create()!
        defer { dsp_kernel_destroy(kernel) }
        dsp_kernel_set_licensed(kernel, true)
        dsp_kernel_initialize(kernel, Int32(Self.channels), Int32(Self.channels), Self.sampleRate)
        dsp_kernel_set_max_frames(kernel, UInt32(Self.chunkSize))

        let loaded = wasmData.withUnsafeBytes { buf in
            dsp_kernel_load_wasm(kernel, buf.baseAddress!.assumingMemoryBound(to: UInt8.self), UInt32(buf.count))
        }
        #expect(loaded, "WASM should load successfully")

        // 3. Verify WASM declares a NAM path
        #expect(dsp_kernel_nam_path_count(kernel) >= 1, "NAM preset should report at least one NAM path")

        // 4. Read and serialize .nam file (same as ExportAUAudioUnit does)
        let namURL = Self.repoRootURL.appendingPathComponent("tone3000_py_demo/lstm_tiny.nam")
        let binary = try Self.serializeNamFile(at: namURL)

        // 5. Inject NAM model
        let injected = binary.withUnsafeBytes { rawBuffer -> Bool in
            guard let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            return dsp_kernel_inject_nam_slot(kernel, 0, ptr, UInt(binary.count))
        }
        #expect(injected, "NAM injection should succeed. Error: \(Self.kernelError(kernel))")

        // 6a. Process SILENCE — output should be near-zero, not static
        let silenceL = [Float](repeating: 0, count: Int(Self.sampleRate * Self.durationSeconds))
        let silenceR = silenceL
        let (silOutL, silOutR) = Self.renderSignal(kernel: kernel, inputL: silenceL, inputR: silenceR)

        let silencePeakL = silOutL.map { abs($0) }.max() ?? 0
        let silencePeakR = silOutR.map { abs($0) }.max() ?? 0
        #expect(silencePeakL < 0.1, "Silence input should not produce loud output (peak L: \(silencePeakL))")
        #expect(silencePeakR < 0.1, "Silence input should not produce loud output (peak R: \(silencePeakR))")

        // 6b. Process SINE WAVE
        let (inputL, inputR) = Self.generateSineSignal()
        let (outputL, outputR) = Self.renderSignal(kernel: kernel, inputL: inputL, inputR: inputR)

        // Verify output is finite (no NaN/Inf)
        for i in 0..<outputL.count {
            #expect(outputL[i].isFinite, "Output L[\(i)] is not finite: \(outputL[i])")
            #expect(outputR[i].isFinite, "Output R[\(i)] is not finite: \(outputR[i])")
        }

        // Verify output is not all zeros (model is processing)
        let outputPeakL = outputL.map { abs($0) }.max() ?? 0
        #expect(outputPeakL > 1e-6, "Output should not be silent (peak L: \(outputPeakL))")

        // Verify output differs from input (model modifies signal)
        var maxDiff: Float = 0
        for i in 0..<inputL.count {
            maxDiff = max(maxDiff, abs(outputL[i] - inputL[i]))
        }
        #expect(maxDiff > 1e-4, "Output should differ from input (maxDiff: \(maxDiff))")
    }

    @Test("NAM WaveNet preset processes audio correctly (not static)")
    func namWavenetPresetProducesCorrectAudio() throws {
        // 1. Compile NAM preset source to WASM
        let resourcesURL = try Self.extensionResourcesURL
        let source = try String(contentsOf: resourcesURL.appendingPathComponent("presets/preset_nam_rust.cdp/process.rs"), encoding: .utf8)
        let wasmData = try Self.compileToWasm(source: source)

        // 2. Create kernel and load WASM
        let kernel = dsp_kernel_create()!
        defer { dsp_kernel_destroy(kernel) }
        dsp_kernel_set_licensed(kernel, true)
        dsp_kernel_initialize(kernel, Int32(Self.channels), Int32(Self.channels), Self.sampleRate)
        dsp_kernel_set_max_frames(kernel, UInt32(Self.chunkSize))

        let loaded = wasmData.withUnsafeBytes { buf in
            dsp_kernel_load_wasm(kernel, buf.baseAddress!.assumingMemoryBound(to: UInt8.self), UInt32(buf.count))
        }
        #expect(loaded, "WASM should load successfully")

        // 3. Verify WASM declares a NAM path
        #expect(dsp_kernel_nam_path_count(kernel) >= 1, "NAM preset should report at least one NAM path")

        // 4. Read and serialize .nam file (same as ExportAUAudioUnit does)
        let namURL = Self.repoRootURL.appendingPathComponent("tone3000_py_demo/wavenet_tiny.nam")
        let binary = try Self.serializeNamFile(at: namURL)

        // 5. Inject NAM model
        let injected = binary.withUnsafeBytes { rawBuffer -> Bool in
            guard let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            return dsp_kernel_inject_nam_slot(kernel, 0, ptr, UInt(binary.count))
        }
        #expect(injected, "NAM injection should succeed. Error: \(Self.kernelError(kernel))")

        // 6a. Process SILENCE — output should be near-zero, not static
        let silenceL = [Float](repeating: 0, count: Int(Self.sampleRate * Self.durationSeconds))
        let silenceR = silenceL
        let (silOutL, silOutR) = Self.renderSignal(kernel: kernel, inputL: silenceL, inputR: silenceR)

        let silencePeakL = silOutL.map { abs($0) }.max() ?? 0
        let silencePeakR = silOutR.map { abs($0) }.max() ?? 0
        #expect(silencePeakL < 0.1, "Silence input should not produce loud output (peak L: \(silencePeakL))")
        #expect(silencePeakR < 0.1, "Silence input should not produce loud output (peak R: \(silencePeakR))")

        // 6b. Process SINE WAVE
        let (inputL, inputR) = Self.generateSineSignal()
        let (outputL, outputR) = Self.renderSignal(kernel: kernel, inputL: inputL, inputR: inputR)

        // Verify output is finite (no NaN/Inf)
        for i in 0..<outputL.count {
            #expect(outputL[i].isFinite, "Output L[\(i)] is not finite: \(outputL[i])")
            #expect(outputR[i].isFinite, "Output R[\(i)] is not finite: \(outputR[i])")
        }

        // Verify output is not all zeros (model is processing)
        let outputPeakL = outputL.map { abs($0) }.max() ?? 0
        #expect(outputPeakL > 1e-6, "Output should not be silent (peak L: \(outputPeakL))")

        // Verify output differs from input (model modifies signal)
        var maxDiff: Float = 0
        for i in 0..<inputL.count {
            maxDiff = max(maxDiff, abs(outputL[i] - inputL[i]))
        }
        #expect(maxDiff > 1e-4, "Output should differ from input (maxDiff: \(maxDiff))")
    }

    // MARK: - NAM Export Pipeline Tests

    @Test("Export Python NAM preset: bundle has model.nam, preset.py is rewritten, runtime-config has namModelFile")
    func exportPythonNamPresetBundleIsCorrect() throws {
        guard let templateURL = findRealTemplate() else {
            print("Skipping: ExportTemplate.zip not found")
            return
        }

        let testId = UUID().uuidString.prefix(8)
        let (outputDir, registryURL) = try makeTempOutputDir(testId: String(testId))
        defer {
            try? FileManager.default.removeItem(at: outputDir)
            try? FileManager.default.removeItem(at: registryURL.deletingLastPathComponent())
        }

        // 1. Read Python NAM preset and replace the default tone3000 URL with a real absolute path
        let namURL = Self.repoRootURL.appendingPathComponent("tone3000_py_demo/lstm_tiny.nam")
        let resourcesURL = try Self.extensionResourcesURL
        var source = try String(contentsOf: resourcesURL.appendingPathComponent("presets/preset_nam.cdp/process.py"), encoding: .utf8)
        source = source.replacingOccurrences(of: "tone3000://19/56", with: namURL.path)
        #expect(source.contains(namURL.path), "Source should contain absolute NAM path after substitution")

        // 2. Export
        let registry = ExportRegistry(registryURL: registryURL)
        let manager = ExportManager(registry: registry)
        let appURL = try manager.exportPreset(
            name: "ExportTest_PythonNAM_\(testId)",
            source: source,
            wasmData: nil,
            language: .python,
            templateURL: templateURL,
            outputDirectory: outputDir,
            skipSigning: true
        )

        let resources = appexResourcesPath(in: appURL)

        // 3. model.nam must be present in the bundle
        let exportedNamURL = resources.appendingPathComponent("model.nam")
        #expect(FileManager.default.fileExists(atPath: exportedNamURL.path),
                "model.nam should be present in exported bundle")

        // 4. preset.py must have the load_model call rewritten to "model.nam"
        let exportedPy = try String(contentsOf: resources.appendingPathComponent("preset.py"), encoding: .utf8)
        #expect(exportedPy.contains(#"load_model("model.nam")"#),
                "Exported preset.py should reference model.nam, not the original path")
        // The load_model() call itself must not have the original path (comments may still contain it)
        #expect(!exportedPy.contains("load_model(\"\(namURL.path)\")"),
                "load_model() call in exported preset.py should not contain the original absolute path")

        // 5. runtime-config.json must record namModelFile
        let configData = try Data(contentsOf: resources.appendingPathComponent("runtime-config.json"))
        let config = try JSONSerialization.jsonObject(with: configData) as! [String: Any]
        #expect(config["namModelFile"] as? String == "model.nam",
                "runtime-config.json should have namModelFile = \"model.nam\"")

        // 6. Exported model.nam must be byte-for-byte identical to the source file
        let exportedNamData = try Data(contentsOf: exportedNamURL)
        let originalNamData = try Data(contentsOf: namURL)
        #expect(exportedNamData == originalNamData,
                "Exported model.nam should match original lstm_tiny.nam")
    }

    @Test("Export Rust NAM preset: bundle has model.nam, runtime-config correct, audio processes correctly")
    func exportRustNamPresetBundleAndVerifyAudio() throws {
        guard let templateURL = findRealTemplate() else {
            print("Skipping: ExportTemplate.zip not found")
            return
        }

        let testId = UUID().uuidString.prefix(8)
        let (outputDir, registryURL) = try makeTempOutputDir(testId: String(testId))
        defer {
            try? FileManager.default.removeItem(at: outputDir)
            try? FileManager.default.removeItem(at: registryURL.deletingLastPathComponent())
        }

        // 1. Read Rust NAM preset and replace the default tone3000 URL with a real absolute path
        let namURL = Self.repoRootURL.appendingPathComponent("tone3000_py_demo/lstm_tiny.nam")
        let resourcesURL = try Self.extensionResourcesURL
        var source = try String(contentsOf: resourcesURL.appendingPathComponent("presets/preset_nam_rust.cdp/process.rs"), encoding: .utf8)
        source = source.replacingOccurrences(of: "tone3000://19/56", with: namURL.path)
        #expect(source.contains(namURL.path), "Source should contain absolute NAM path after substitution")

        // 2. Compile to WASM
        let wasmData = try Self.compileToWasm(source: source)

        // 3. Export
        let registry = ExportRegistry(registryURL: registryURL)
        let manager = ExportManager(registry: registry)
        let appURL = try manager.exportPreset(
            name: "ExportTest_RustNAM_\(testId)",
            source: source,
            wasmData: wasmData,
            language: .rust,
            templateURL: templateURL,
            outputDirectory: outputDir,
            skipSigning: true
        )

        let resources = appexResourcesPath(in: appURL)

        // 4. model.nam must be present in the bundle
        let exportedNamURL = resources.appendingPathComponent("model.nam")
        #expect(FileManager.default.fileExists(atPath: exportedNamURL.path),
                "model.nam should be present in exported bundle")

        // 5. runtime-config.json must record namModelFile
        let configData = try Data(contentsOf: resources.appendingPathComponent("runtime-config.json"))
        let config = try JSONSerialization.jsonObject(with: configData) as! [String: Any]
        #expect(config["namModelFile"] as? String == "model.nam",
                "runtime-config.json should have namModelFile = \"model.nam\"")

        // 6. Exported model.nam must be byte-for-byte identical to the source file
        let exportedNamData = try Data(contentsOf: exportedNamURL)
        let originalNamData = try Data(contentsOf: namURL)
        #expect(exportedNamData == originalNamData,
                "Exported model.nam should match original lstm_tiny.nam")

        // 7. Audio round-trip: load exported WASM + inject exported model.nam, verify output
        let exportedWasm = try Data(contentsOf: resources.appendingPathComponent("preset.wasm"))

        let kernel = dsp_kernel_create()!
        defer { dsp_kernel_destroy(kernel) }
        dsp_kernel_set_licensed(kernel, true)
        dsp_kernel_initialize(kernel, Int32(Self.channels), Int32(Self.channels), Self.sampleRate)
        dsp_kernel_set_max_frames(kernel, UInt32(Self.chunkSize))

        let loaded = exportedWasm.withUnsafeBytes { buf in
            dsp_kernel_load_wasm(kernel, buf.baseAddress!.assumingMemoryBound(to: UInt8.self), UInt32(buf.count))
        }
        #expect(loaded, "Exported WASM should load successfully into kernel")

        // Serialize and inject the exported model.nam (same binary protocol as ExportAUAudioUnit)
        let binary = try Self.serializeNamFile(at: exportedNamURL)
        let injected = binary.withUnsafeBytes { rawBuffer -> Bool in
            guard let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            return dsp_kernel_inject_nam_slot(kernel, 0, ptr, UInt(binary.count))
        }
        #expect(injected, "NAM injection from exported model.nam should succeed. Error: \(Self.kernelError(kernel))")

        // Process silence — must not produce loud output (not static)
        let silenceL = [Float](repeating: 0, count: Int(Self.sampleRate * Self.durationSeconds))
        let silenceR = silenceL
        let (silOutL, silOutR) = Self.renderSignal(kernel: kernel, inputL: silenceL, inputR: silenceR)
        let silencePeakL = silOutL.map { abs($0) }.max() ?? 0
        let silencePeakR = silOutR.map { abs($0) }.max() ?? 0
        #expect(silencePeakL < 0.1, "Silence input should not produce loud output (peak L: \(silencePeakL))")
        #expect(silencePeakR < 0.1, "Silence input should not produce loud output (peak R: \(silencePeakR))")

        // Process sine wave — must be finite, non-silent, and differ from input
        let (inputL, inputR) = Self.generateSineSignal()
        let (outputL, outputR) = Self.renderSignal(kernel: kernel, inputL: inputL, inputR: inputR)

        for i in 0..<outputL.count {
            #expect(outputL[i].isFinite, "Output L[\(i)] is not finite: \(outputL[i])")
            #expect(outputR[i].isFinite, "Output R[\(i)] is not finite: \(outputR[i])")
        }

        let outputPeakL = outputL.map { abs($0) }.max() ?? 0
        #expect(outputPeakL > 1e-6, "Output should not be silent (peak L: \(outputPeakL))")

        var maxDiff: Float = 0
        for i in 0..<inputL.count {
            maxDiff = max(maxDiff, abs(outputL[i] - inputL[i]))
        }
        #expect(maxDiff > 1e-4, "Output should differ from input (maxDiff: \(maxDiff))")
    }

    @Test("Export NAM preset throws namModelNotFound when model file does not exist")
    func exportNamPresetThrowsWhenModelMissing() throws {
        guard let templateURL = findRealTemplate() else {
            print("Skipping: ExportTemplate.zip not found")
            return
        }

        let testId = UUID().uuidString.prefix(8)
        let (outputDir, registryURL) = try makeTempOutputDir(testId: String(testId))
        defer {
            try? FileManager.default.removeItem(at: outputDir)
            try? FileManager.default.removeItem(at: registryURL.deletingLastPathComponent())
        }

        // Minimal Python NAM source referencing a nonexistent absolute path
        let source = """
            from conjuredsp.nam import load_model
            model = load_model("/nonexistent/bogus/model.nam")
            def process(ctx):
                pass
            """

        let registry = ExportRegistry(registryURL: registryURL)
        let manager = ExportManager(registry: registry)

        #expect(throws: ExportManager.ExportError.self) {
            try manager.exportPreset(
                name: "ExportTest_MissingNAM_\(testId)",
                source: source,
                wasmData: nil,
                language: .python,
                templateURL: templateURL,
                outputDirectory: outputDir,
                skipSigning: true
            )
        }
    }

    // MARK: - Custom UI

    /// Export a Python preset with a `ui/index.html` attached. Verify the
    /// exported appex carries the UI files in Resources/ui/ and that
    /// runtime-config.json has `hasCustomUI: true` plus a `ui` block. This
    /// is the path that fails when a user exports a custom-UI preset and
    /// finds a blank webview in their DAW.
    @Test("Export preset with custom UI: ui/ copied, runtime-config has hasCustomUI + ui block")
    func exportWithCustomUI() throws {
        guard let templateURL = findRealTemplate() else {
            print("Skipping: ExportTemplate.zip not found")
            return
        }

        let testId = UUID().uuidString.prefix(8)
        let (outputDir, registryURL) = try makeTempOutputDir(testId: String(testId))
        defer {
            try? FileManager.default.removeItem(at: outputDir)
            try? FileManager.default.removeItem(at: registryURL.deletingLastPathComponent())
        }

        // 1. Build a fake bundle UI directory on disk with an index.html + asset.
        let fm = FileManager.default
        let fakeBundleUIDir = fm.temporaryDirectory
            .appendingPathComponent("ExportUITestBundle_\(testId)")
            .appendingPathComponent("ui", isDirectory: true)
        try fm.createDirectory(at: fakeBundleUIDir, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: fakeBundleUIDir.deletingLastPathComponent())
        }

        let indexHTML = """
            <!DOCTYPE html>
            <html><body><h1>Custom</h1>
            <script src="ui/assets/bridge.js"></script>
            </body></html>
            """
        try indexHTML.write(
            to: fakeBundleUIDir.appendingPathComponent("index.html"),
            atomically: true, encoding: .utf8
        )
        let assetsDir = fakeBundleUIDir.appendingPathComponent("assets", isDirectory: true)
        try fm.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        try "/* style */".write(
            to: assetsDir.appendingPathComponent("style.css"),
            atomically: true, encoding: .utf8
        )

        // 2. Source script — any simple Python will do; the UI is what we're
        //    testing.
        let source = """
            def process(ctx):
                for ch in range(len(ctx.inputs)):
                    ctx.outputs[ch][:ctx.frame_count] = ctx.inputs[ch][:ctx.frame_count]
            """

        // 3. Export with a CustomUIPayload pointing at the fake ui/ tree.
        let payload = ExportManager.CustomUIPayload(
            directory: fakeBundleUIDir,
            entryHTML: "index.html",
            width: 520,
            height: 260,
            fps: 30,
            audioFrames: false
        )

        let registry = ExportRegistry(registryURL: registryURL)
        let manager = ExportManager(registry: registry)
        let appURL = try manager.exportPreset(
            name: "ExportTest_CustomUI_\(testId)",
            source: source,
            wasmData: nil,
            language: .python,
            templateURL: templateURL,
            outputDirectory: outputDir,
            skipSigning: true,
            customUI: payload
        )

        // 4. Verify ui/ and its contents landed inside the appex.
        let appexResources = appexResourcesPath(in: appURL)
        let embeddedUI = appexResources.appendingPathComponent("ui", isDirectory: true)
        #expect(fm.fileExists(atPath: embeddedUI.path),
                "Exported appex must contain Resources/ui/ directory")

        let embeddedIndex = embeddedUI.appendingPathComponent("index.html")
        #expect(fm.fileExists(atPath: embeddedIndex.path),
                "Exported appex must contain ui/index.html")
        let embeddedIndexContents = try String(contentsOf: embeddedIndex, encoding: .utf8)
        #expect(embeddedIndexContents == indexHTML,
                "Embedded index.html should match source verbatim")

        let embeddedAsset = embeddedUI.appendingPathComponent("assets/style.css")
        #expect(fm.fileExists(atPath: embeddedAsset.path),
                "Exported appex must preserve ui/assets/ subtree")

        // 5. Verify runtime-config.json carries the hasCustomUI flag + ui block.
        let configURL = appexResources.appendingPathComponent("runtime-config.json")
        let configData = try Data(contentsOf: configURL)
        guard let configJSON = try JSONSerialization.jsonObject(with: configData) as? [String: Any] else {
            Issue.record("runtime-config.json could not be parsed as an object")
            return
        }
        #expect(configJSON["hasCustomUI"] as? Bool == true,
                "runtime-config.json must set hasCustomUI: true — without this the AU falls back to generic sliders")
        guard let uiBlock = configJSON["ui"] as? [String: Any] else {
            Issue.record("runtime-config.json missing `ui` block — the export template's RuntimeConfig.customUIEntryURL(in:) will return nil and render generic sliders")
            return
        }
        #expect(uiBlock["entryHTML"] as? String == "index.html")
        #expect(uiBlock["width"] as? Int == 520)
        #expect(uiBlock["height"] as? Int == 260)
        #expect(uiBlock["fps"] as? Int == 30)
    }

    /// The exported AU's WebContent process needs
    /// `com.apple.security.network.client` or it crashes on launch with
    /// "Application does not have permission to communicate with network
    /// resources", causing the custom UI to render blank. This test reads
    /// the entitlements embedded in the ExportTemplate.zip's signed appex
    /// and fails loudly if that entitlement is missing.
    ///
    /// Does NOT require an export — inspects the template directly so it
    /// catches an entitlements regression the moment the template is
    /// rebuilt, not after a user tries to load an exported AU in a DAW.
    @Test("Export template ships com.apple.security.network.client — required for WKWebView WebContent process")
    func exportTemplateHasNetworkClientEntitlement() throws {
        guard let templateURL = findRealTemplate() else {
            print("Skipping: ExportTemplate.zip not found")
            return
        }

        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
            .appendingPathComponent("ExportEntitlementsTest_\(UUID().uuidString.prefix(8))")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        // Unzip template into temp dir.
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", templateURL.path, "-d", tmp.path]
        try unzip.run()
        unzip.waitUntilExit()
        #expect(unzip.terminationStatus == 0, "unzip failed")

        let appexURL = tmp
            .appendingPathComponent("ConjureDSPExportAUTemplate.app")
            .appendingPathComponent("Contents/PlugIns/ConjureDSPExportAUTemplateExtension.appex")
        guard fm.fileExists(atPath: appexURL.path) else {
            Issue.record("Expected extracted appex at \(appexURL.path)")
            return
        }

        // Read embedded entitlements via codesign.
        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = ["-d", "--entitlements", "-", "--xml", appexURL.path]
        let stdout = Pipe()
        codesign.standardOutput = stdout
        codesign.standardError = Pipe()
        try codesign.run()
        codesign.waitUntilExit()
        #expect(codesign.terminationStatus == 0, "codesign failed with status \(codesign.terminationStatus)")

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let xml = String(data: data, encoding: .utf8) else {
            Issue.record("Entitlements output was not UTF-8")
            return
        }

        // Text-based assertion is more robust than plist parsing across
        // codesign's various output prefix formats (XML, CMS-wrapped XML,
        // etc.). We're looking for the key followed by <true/>.
        let pattern = #"<key>com\.apple\.security\.network\.client</key>\s*<true/>"#
        #expect(xml.range(of: pattern, options: .regularExpression) != nil,
                "Export template appex is MISSING com.apple.security.network.client — WKWebView's WebContent process will crash on launch in every exported AU. Add the entitlement to ConjureDSPExportAUTemplateExtension.entitlements and rebuild the template. Full entitlements dump: \(xml)")
    }

    /// End-to-end roundtrip: call the same `PresetManager.savePreset(scaffoldUI:)`
    /// the UI's "+ Add Custom UI" / Save-As-with-Custom-UI paths use, then
    /// export that bundle via `ExportManager`, then verify the ui/index.html
    /// in the exported appex byte-for-byte matches `PresetBundle.starterIndexHTML()`.
    ///
    /// Catches three classes of regression in one shot:
    ///   1. scaffoldUI produces an HTML file that drifts from the canonical
    ///      `starterIndexHTML()` (e.g. someone edited the scaffold path).
    ///   2. ExportManager drops or modifies the ui/ payload between source
    ///      bundle and exported appex.
    ///   3. The CSS/layout improvements we ship in `starterIndexHTML()`
    ///      fail to reach the exported bundle.
    ///
    /// Doesn't verify visual rendering (WKWebView layout still needs a
    /// DAW or manual test), but it eliminates the "did my change actually
    /// propagate through save + export" question.
    @Test("End-to-end: scaffoldUI save → export → starter HTML matches byte-for-byte")
    @MainActor
    func scaffoldSaveExportRoundtrip() throws {
        guard let templateURL = findRealTemplate() else {
            print("Skipping: ExportTemplate.zip not found")
            return
        }

        let fm = FileManager.default
        let testId = UUID().uuidString.prefix(8)

        // 1. Set up an isolated preset directory and save a bundle with
        //    scaffoldUI: true — same path the in-plugin "+ Add Custom UI"
        //    and Save-As-with-Custom-UI buttons take.
        let presetsDir = fm.temporaryDirectory
            .appendingPathComponent("RoundtripPresets_\(testId)", isDirectory: true)
        try fm.createDirectory(at: presetsDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: presetsDir) }

        guard let extensionBundleURL = Bundle.main.builtInPlugInsURL?
                .appendingPathComponent("ConjureDSPExtension.appex"),
              let extensionBundle = Bundle(url: extensionBundleURL) else {
            Issue.record("Extension bundle not available")
            return
        }

        let presetName = "RoundtripPreset_\(testId)"
        let source = """
            def process(ctx):
                for ch in range(len(ctx.inputs)):
                    ctx.outputs[ch][:ctx.frame_count] = ctx.inputs[ch][:ctx.frame_count]
            """
        let mgr = PresetManager(extensionBundle: extensionBundle, presetsURL: presetsDir)
        let preset = try mgr.savePreset(
            name: presetName, source: source,
            language: .python, scaffoldUI: true
        )
        guard let savedBundleURL = preset.fileURL else {
            Issue.record("Saved preset has no fileURL")
            return
        }

        // 2. The bundle's ui/index.html must match starterIndexHTML() exactly.
        let savedHTMLURL = savedBundleURL.appendingPathComponent("ui/index.html")
        let savedHTML = try String(contentsOf: savedHTMLURL, encoding: .utf8)
        let canonicalHTML = PresetBundle.starterIndexHTML()
        #expect(savedHTML == canonicalHTML,
                "Bundle's ui/index.html drifted from PresetBundle.starterIndexHTML() — the scaffold is writing something different than the source of truth")

        // 3. Canonical HTML must include the markers that tie the starter
        //    to the injected `cdp-ui` component library. If someone reverts
        //    the library integration — swapping back to a hand-rolled slider
        //    list or breaking the vertical centering layout — this fails
        //    loudly instead of silently regressing.
        #expect(canonicalHTML.contains("justify-content: center"),
                "Starter HTML must center rows vertically (single-param UIs otherwise leave a huge empty region below the slider)")
        #expect(canonicalHTML.contains("<cdp-panel auto"),
                "Starter HTML must use the <cdp-panel auto> component from the injected cdp-ui library")

        // 4. Build a CustomUIPayload from the saved bundle and run export.
        guard let bundle = PresetBundle.load(from: savedBundleURL) else {
            Issue.record("Failed to load saved bundle for export")
            return
        }
        guard let uiDir = bundle.uiDirectoryURL else {
            Issue.record("Saved bundle missing uiDirectoryURL despite scaffoldUI: true")
            return
        }
        let uiMeta = bundle.manifest.ui
        let payload = ExportManager.CustomUIPayload(
            directory: uiDir,
            entryHTML: {
                let p = bundle.manifest.uiEntryHTMLPath
                return p.hasPrefix("ui/") ? String(p.dropFirst(3)) : p
            }(),
            width: uiMeta?.width,
            height: uiMeta?.height,
            fps: bundle.manifest.resolvedFPS,
            audioFrames: bundle.manifest.audioFramesEnabled
        )

        let (outputDir, registryURL) = try makeTempOutputDir(testId: String(testId))
        defer {
            try? fm.removeItem(at: outputDir)
            try? fm.removeItem(at: registryURL.deletingLastPathComponent())
        }
        let registry = ExportRegistry(registryURL: registryURL)
        let manager = ExportManager(registry: registry)
        let appURL = try manager.exportPreset(
            name: "RoundtripExport_\(testId)",
            source: source,
            wasmData: nil,
            language: .python,
            templateURL: templateURL,
            outputDirectory: outputDir,
            skipSigning: true,
            customUI: payload
        )

        // 5. The exported appex's ui/index.html must be byte-identical to
        //    what we saved and to the canonical starter. If ExportManager
        //    ever starts rewriting ui/* files, this catches it.
        let exportedHTMLURL = appexResourcesPath(in: appURL)
            .appendingPathComponent("ui/index.html")
        let exportedHTML = try String(contentsOf: exportedHTMLURL, encoding: .utf8)
        #expect(exportedHTML == savedHTML,
                "Exported ui/index.html drifted from the saved bundle's copy")
        #expect(exportedHTML == canonicalHTML,
                "Exported ui/index.html drifted from PresetBundle.starterIndexHTML()")
    }

    /// Export without a custom UI must NOT produce a ui/ directory in the
    /// appex and must NOT set hasCustomUI. Exists to prove the export path
    /// is only invasive when explicitly opted into.
    @Test("Export without custom UI leaves runtime-config.hasCustomUI unset and creates no ui/ directory")
    func exportWithoutCustomUIIsClean() throws {
        guard let templateURL = findRealTemplate() else {
            print("Skipping: ExportTemplate.zip not found")
            return
        }

        let testId = UUID().uuidString.prefix(8)
        let (outputDir, registryURL) = try makeTempOutputDir(testId: String(testId))
        defer {
            try? FileManager.default.removeItem(at: outputDir)
            try? FileManager.default.removeItem(at: registryURL.deletingLastPathComponent())
        }

        let source = """
            def process(ctx):
                pass
            """

        let registry = ExportRegistry(registryURL: registryURL)
        let manager = ExportManager(registry: registry)
        let appURL = try manager.exportPreset(
            name: "ExportTest_NoCustomUI_\(testId)",
            source: source,
            wasmData: nil,
            language: .python,
            templateURL: templateURL,
            outputDirectory: outputDir,
            skipSigning: true
        )

        let appexResources = appexResourcesPath(in: appURL)
        let fm = FileManager.default

        // No ui/ embedded — either the directory doesn't exist, or the
        // template shipped one and the exporter didn't touch it. A test
        // that asserts absence of a `ui/index.html` is defensible either
        // way, since the template shouldn't ship user-facing UI files.
        let embeddedIndex = appexResources.appendingPathComponent("ui/index.html")
        #expect(!fm.fileExists(atPath: embeddedIndex.path),
                "Export without custom UI must not leave ui/index.html in appex")

        let configURL = appexResources.appendingPathComponent("runtime-config.json")
        let configData = try Data(contentsOf: configURL)
        guard let configJSON = try JSONSerialization.jsonObject(with: configData) as? [String: Any] else {
            Issue.record("runtime-config.json could not be parsed")
            return
        }
        let hasCustomUI = configJSON["hasCustomUI"] as? Bool ?? false
        #expect(!hasCustomUI,
                "Export without custom UI must NOT set hasCustomUI — otherwise the template switches to the (empty) custom UI path")
    }
}

// MARK: - Edge Case Tests

struct ExportEdgeCaseTests {

    @Test func exportPresetNameWithUnicode() {
        let sanitized = ExportManager.sanitizeName("超级混响 🎵 Effect!")
        // Unicode chars and emoji become underscores
        #expect(!sanitized.isEmpty)
        #expect(!sanitized.contains("🎵"))
        // Should only contain alphanumeric, hyphens, underscores
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        for scalar in sanitized.unicodeScalars {
            #expect(allowed.contains(scalar), "Unexpected char: \(scalar)")
        }
    }

    @Test func exportPresetNameAllSpecialChars() {
        let sanitized = ExportManager.sanitizeName("!!@@##$$")
        #expect(sanitized == "Untitled", "All-special-char name should fall back to Untitled")
    }

    @Test func exportPresetNameEmpty() {
        let sanitized = ExportManager.sanitizeName("")
        #expect(sanitized == "Untitled", "Empty name should fall back to Untitled")
    }

    @Test func exportPresetNameOnlyUnderscores() {
        let sanitized = ExportManager.sanitizeName("___")
        // After trimming underscores, this becomes empty → Untitled
        #expect(sanitized == "Untitled")
    }

    @Test func exportPresetNameWithSpaces() {
        let sanitized = ExportManager.sanitizeName("My Cool Reverb")
        #expect(sanitized == "My_Cool_Reverb")
    }
}

// MARK: - NAM Reference Detection Tests

struct ExportNamReferenceTests {

    @Test func pythonTone3000Reference() {
        let source = """
        from conjuredsp.nam import load_model
        model = load_model("tone3000://60092/351559")
        def process(ctx):
            pass
        """
        #expect(ExportManager.containsNamReference(source: source, language: .python))
    }

    @Test func pythonLocalFileReference() {
        let source = #"model = load_model("/Users/foo/models/my_amp.nam")"#
        #expect(ExportManager.containsNamReference(source: source, language: .python))
    }

    @Test func pythonTildeFileReference() {
        let source = #"m = load_model("~/Music/tones/lead.nam")"#
        #expect(ExportManager.containsNamReference(source: source, language: .python))
    }

    @Test func rustTone3000Reference() {
        let source = """
        use conjuredsp::*;
        conjuredsp::nam!("tone3000://60092/351559");
        """
        #expect(ExportManager.containsNamReference(source: source, language: .rust))
    }

    @Test func rustLocalFileReference() {
        let source = #"nam!("/Users/foo/bar.nam");"#
        #expect(ExportManager.containsNamReference(source: source, language: .rust))
    }

    @Test func pythonWithoutNamReference() {
        let source = """
        def process(ctx):
            ctx.outputs[:] = ctx.inputs * ctx.params["gain"]
        """
        #expect(!ExportManager.containsNamReference(source: source, language: .python))
    }

    @Test func rustWithoutNamReference() {
        let source = """
        use conjuredsp::*;
        setup!();
        params! { GAIN = db() }
        fn process() {}
        """
        #expect(!ExportManager.containsNamReference(source: source, language: .rust))
    }

    @Test func pythonMacroPatternIgnoredForPython() {
        // Rust nam!(...) macro should not match the Python detector.
        let source = #"# nam!("tone3000://1/2")"#
        #expect(!ExportManager.containsNamReference(source: source, language: .python))
    }

    @Test func rustLoadModelIgnoredForRust() {
        // Python load_model() call should not match the Rust detector.
        let source = #"// load_model("foo.nam")"#
        #expect(!ExportManager.containsNamReference(source: source, language: .rust))
    }
}

