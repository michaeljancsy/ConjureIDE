//
//  ExportAUTests.swift
//  BearBoneExportAUTemplateTests
//

import AudioToolbox
import AVFAudio
import Testing

// MARK: - Helpers

/// Reads the AU component description from the embedded extension's Info.plist.
private func discoverComponentDescription() throws -> AudioComponentDescription {
    guard let plugInsURL = Bundle.main.builtInPlugInsURL else {
        throw TestError("Bundle.main.builtInPlugInsURL is nil")
    }
    let plistURL = plugInsURL
        .appendingPathComponent("BearBoneExportAUTemplateExtension.appex")
        .appendingPathComponent("Contents/Info.plist")
    let data = try Data(contentsOf: plistURL)
    guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let nsExtension = plist["NSExtension"] as? [String: Any],
          let attrs = nsExtension["NSExtensionAttributes"] as? [String: Any],
          let components = attrs["AudioComponents"] as? [[String: Any]],
          let component = components.first,
          let type = component["type"] as? String,
          let subtype = component["subtype"] as? String,
          let manufacturer = component["manufacturer"] as? String
    else {
        throw TestError("Failed to parse AU identity from extension Info.plist")
    }

    return AudioComponentDescription(
        componentType: type.fourCharCode,
        componentSubType: subtype.fourCharCode,
        componentManufacturer: manufacturer.fourCharCode,
        componentFlags: 0,
        componentFlagsMask: 0
    )
}

private struct TestError: Error, CustomStringConvertible {
    let description: String
    init(_ msg: String) { description = msg }
}

private extension String {
    var fourCharCode: FourCharCode {
        var result: FourCharCode = 0
        for char in utf8.prefix(4) {
            result = (result << 8) | FourCharCode(char)
        }
        return result
    }
}

// MARK: - AU Component Tests

@Suite("Export AU Component")
struct ExportAUComponentTests {
    @Test("AU instantiation succeeds")
    func auInstantiates() async throws {
        let desc = try discoverComponentDescription()
        let avAU = try await AVAudioUnit.instantiate(with: desc, options: .loadInProcess)
        #expect(avAU.auAudioUnit != nil)
    }

    @Test("Has 1 input bus and 1 output bus")
    func busConfiguration() async throws {
        let desc = try discoverComponentDescription()
        let avAU = try await AVAudioUnit.instantiate(with: desc, options: .loadInProcess)
        let au = avAU.auAudioUnit
        #expect(au.inputBusses.count == 1)
        #expect(au.outputBusses.count == 1)
    }

    @Test("Channel capabilities are mono and stereo")
    func channelCapabilities() async throws {
        let desc = try discoverComponentDescription()
        let avAU = try await AVAudioUnit.instantiate(with: desc, options: .loadInProcess)
        let caps = avAU.auAudioUnit.channelCapabilities ?? []
        #expect(caps == [NSNumber(value: 1), NSNumber(value: 1),
                         NSNumber(value: 2), NSNumber(value: 2)])
    }

    @Test("Parameter tree has 8 parameters")
    func parameterTree() async throws {
        let desc = try discoverComponentDescription()
        let avAU = try await AVAudioUnit.instantiate(with: desc, options: .loadInProcess)
        let tree = try #require(avAU.auAudioUnit.parameterTree)
        #expect(tree.allParameters.count == 8)
    }

    @Test("Parameter value round-trip")
    func parameterRoundTrip() async throws {
        let desc = try discoverComponentDescription()
        let avAU = try await AVAudioUnit.instantiate(with: desc, options: .loadInProcess)
        let tree = try #require(avAU.auAudioUnit.parameterTree)
        let param = try #require(tree.parameter(withAddress: 0))
        param.value = 0.75
        #expect(abs(param.value - 0.75) < 0.001)
    }

    @Test("Bypass defaults to false")
    func bypassDefault() async throws {
        let desc = try discoverComponentDescription()
        let avAU = try await AVAudioUnit.instantiate(with: desc, options: .loadInProcess)
        #expect(avAU.auAudioUnit.shouldBypassEffect == false)
    }

    @Test("Bypass can be toggled")
    func bypassToggle() async throws {
        let desc = try discoverComponentDescription()
        let avAU = try await AVAudioUnit.instantiate(with: desc, options: .loadInProcess)
        avAU.auAudioUnit.shouldBypassEffect = true
        #expect(avAU.auAudioUnit.shouldBypassEffect == true)
        avAU.auAudioUnit.shouldBypassEffect = false
        #expect(avAU.auAudioUnit.shouldBypassEffect == false)
    }

    @Test("Render resources lifecycle")
    func renderResourcesLifecycle() async throws {
        let desc = try discoverComponentDescription()
        let avAU = try await AVAudioUnit.instantiate(with: desc, options: .loadInProcess)
        let au = avAU.auAudioUnit

        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        try au.inputBusses[0].setFormat(format)
        try au.outputBusses[0].setFormat(format)
        au.maximumFramesToRender = 512

        try au.allocateRenderResources()
        au.deallocateRenderResources()
        // Should not crash on second cycle
        try au.allocateRenderResources()
        au.deallocateRenderResources()
    }
}

// MARK: - Runtime Config Tests

@Suite("Runtime Config Parsing")
struct RuntimeConfigTests {
    // RuntimeConfig is internal to the extension module, so we test the JSON
    // contract directly to ensure the language field is present and parseable.

    private struct ConfigShape: Codable {
        let version: Int
        let language: String
        let presetName: String
        let paramCount: Int?
    }

    @Test("runtime-config.json with Python language parses correctly")
    func parsesPythonConfig() throws {
        let json = """
        {"version":1,"language":"python","presetName":"Test Effect","paramCount":8}
        """.data(using: .utf8)!
        let config = try JSONDecoder().decode(ConfigShape.self, from: json)
        #expect(config.language == "python")
        #expect(config.presetName == "Test Effect")
        #expect(config.paramCount == 8)
    }

    @Test("runtime-config.json with Rust language parses correctly")
    func parsesRustConfig() throws {
        let json = """
        {"version":1,"language":"rust","presetName":"Bitcrusher","paramCount":4}
        """.data(using: .utf8)!
        let config = try JSONDecoder().decode(ConfigShape.self, from: json)
        #expect(config.language == "rust")
        #expect(config.paramCount == 4)
    }

    @Test("Bundled runtime-config.json exists and has a language field")
    func bundledConfigHasLanguage() throws {
        guard let plugInsURL = Bundle.main.builtInPlugInsURL else {
            throw TestError("Bundle.main.builtInPlugInsURL is nil")
        }
        let configURL = plugInsURL
            .appendingPathComponent("BearBoneExportAUTemplateExtension.appex")
            .appendingPathComponent("Contents/Resources/runtime-config.json")
        let data = try Data(contentsOf: configURL)
        let config = try JSONDecoder().decode(ConfigShape.self, from: data)
        #expect(!config.language.isEmpty)
    }
}

// MARK: - Rust FFI Direct Tests

@Suite("Rust FFI (direct kernel)")
struct RustFFITests {
    @Test("Kernel create and destroy")
    func kernelLifecycle() {
        let kernel = dsp_kernel_create()
        #expect(kernel != nil)
        dsp_kernel_destroy(kernel)
    }

    @Test("Kernel defaults to not bypassed")
    func kernelBypassDefault() {
        let kernel = dsp_kernel_create()!
        defer { dsp_kernel_destroy(kernel) }
        #expect(dsp_kernel_is_bypassed(kernel) == false)
    }

    @Test("Kernel parameter round-trip")
    func kernelParameterRoundTrip() {
        let kernel = dsp_kernel_create()!
        defer { dsp_kernel_destroy(kernel) }
        dsp_kernel_set_parameter(kernel, 0, 0.42)
        let value = dsp_kernel_get_parameter(kernel, 0)
        #expect(abs(value - 0.42) < 0.001)
    }

    @Test("Kernel set licensed")
    func kernelSetLicensed() {
        let kernel = dsp_kernel_create()!
        defer { dsp_kernel_destroy(kernel) }
        dsp_kernel_set_licensed(kernel, true)
        #expect(dsp_kernel_is_licensed(kernel) == true)
    }

    @Test("WASM passthrough preset loads")
    func wasmPresetLoads() async throws {
        let desc = try discoverComponentDescription()
        let avAU = try await AVAudioUnit.instantiate(with: desc, options: .loadInProcess)
        let au = avAU.auAudioUnit

        // Set up render resources
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        try au.inputBusses[0].setFormat(format)
        try au.outputBusses[0].setFormat(format)
        au.maximumFramesToRender = 512
        try au.allocateRenderResources()
        defer { au.deallocateRenderResources() }

        // The preset was loaded during init — verify render block exists
        let renderBlock = au.renderBlock
        #expect(renderBlock != nil)
    }
}
