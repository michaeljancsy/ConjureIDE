import Foundation
import os.log

private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP", category: "ExportManager")

/// Parameter metadata for export (mirrors ConjureDSPExtensionAudioUnit.ParamMetadata).
/// Defined locally because the test target cannot import the AU extension module.
struct ParamMetadata: Codable {
    let name: String
    let key: String?
    let min: Float
    let max: Float
    let `default`: Float
    let unit: String
    let curve: String?
}

/// Produces a standalone AUv3 .app bundle from a ConjureDSP preset.
///
/// Pipeline: copy template → inject preset → patch plists → code sign → register.
final class ExportManager {
    enum ExportError: LocalizedError {
        case templateNotFound
        case missingWasmData
        case plistPatchFailed(String)
        case codeSignFailed(String)
        case copyFailed(String)
        case validationFailed(String)

        var errorDescription: String? {
            switch self {
            case .templateNotFound: return "Export template not found in app bundle"
            case .missingWasmData: return "Compiled WASM data is required for Rust preset export"
            case .plistPatchFailed(let detail): return "Failed to patch Info.plist: \(detail)"
            case .codeSignFailed(let detail): return "Code signing failed: \(detail)"
            case .copyFailed(let detail): return "Failed to copy template: \(detail)"
            case .validationFailed(let detail): return "Export validation failed: \(detail)"
            }
        }
    }

    let registry: ExportRegistry

    init(registry: ExportRegistry = ExportRegistry()) {
        self.registry = registry
    }

    /// Exports a preset as a standalone AUv3 .app bundle.
    ///
    /// - Parameters:
    ///   - name: Display name for the exported AU.
    ///   - source: Script source code (Python or Rust).
    ///   - wasmData: Compiled WASM bytes (required for Rust, ignored for Python).
    ///   - language: The preset's scripting language.
    ///   - templateURL: URL to the pre-built template .app bundle.
    ///   - outputDirectory: Directory where the exported .app will be written.
    /// - Returns: URL to the exported .app bundle.
    /// App Group identifier shared between host app and AU extension.
    static let appGroupIdentifier = "group.com.MichaelJancsy.ConjureDSP"

    /// Returns the App Group container URL for staging exports.
    static func appGroupContainerURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    func exportPreset(
        name: String,
        source: String,
        wasmData: Data?,
        language: ScriptLanguage,
        templateURL: URL,
        outputDirectory: URL,
        skipSigning: Bool = false,
        paramNames: [Int: String]? = nil,
        paramMetadata: [ParamMetadata]? = nil,
        latencySamples: UInt32 = 0
    ) throws -> URL {
        guard FileManager.default.fileExists(atPath: templateURL.path) else {
            throw ExportError.templateNotFound
        }
        if language == .rust {
            guard wasmData != nil else { throw ExportError.missingWasmData }
        }

        let sanitized = Self.sanitizeName(name)
        let bundleIdBase = "com.ConjureDSP-user.\(sanitized)"
        // Reuse existing subtype for same preset name (re-export/overwrite)
        let subtype = registry.entry(forName: name)?.subtype
            ?? SubtypeGenerator.generate(for: name, existing: registry.allSubtypes())

        // 1. Unzip template (stored as .zip to prevent PluginKit from discovering the .appex)
        let destURL = outputDirectory.appendingPathComponent("\(sanitized).app")
        try unzipTemplate(from: templateURL, to: destURL)

        // 2. Locate the .appex inside the unzipped bundle
        let appexURL = destURL
            .appendingPathComponent("Contents/PlugIns/ConjureDSPExportAUTemplateExtension.appex")
        let appexResourcesURL = appexURL.appendingPathComponent("Contents/Resources")

        // 3. Write preset file
        switch language {
        case .rust:
            try wasmData!.write(to: appexResourcesURL.appendingPathComponent("preset.wasm"))
        case .python:
            try Data(source.utf8).write(to: appexResourcesURL.appendingPathComponent("preset.py"))
            // Remove the placeholder WASM
            let placeholderWasm = appexResourcesURL.appendingPathComponent("preset.wasm")
            if FileManager.default.fileExists(atPath: placeholderWasm.path) {
                try FileManager.default.removeItem(at: placeholderWasm)
            }
        }

        // 4. Write runtime-config.json
        let config = makeRuntimeConfig(name: name, language: language, paramNames: paramNames, paramMetadata: paramMetadata, latencySamples: latencySamples)
        try config.write(to: appexResourcesURL.appendingPathComponent("runtime-config.json"))

        // 5. Patch host app Info.plist
        let appPlistURL = destURL.appendingPathComponent("Contents/Info.plist")
        try patchAppPlist(at: appPlistURL, bundleId: bundleIdBase, displayName: name)

        // 6. Patch extension Info.plist
        let extPlistURL = appexURL.appendingPathComponent("Contents/Info.plist")
        try patchExtensionPlist(
            at: extPlistURL,
            bundleId: "\(bundleIdBase).Extension",
            subtype: subtype,
            displayName: name
        )

        // 7. Ad-hoc code sign (deepest first) — skipped when sandboxed
        // Sign each item inside Frameworks individually (dylibs, .so files).
        // Signing the Frameworks directory itself fails ("bundle format unrecognized").
        if !skipSigning {
            let appexFrameworksURL = appexURL.appendingPathComponent("Contents/Frameworks")
            if FileManager.default.fileExists(atPath: appexFrameworksURL.path) {
                let frameworkItems = try FileManager.default.contentsOfDirectory(
                    at: appexFrameworksURL, includingPropertiesForKeys: nil
                )
                for item in frameworkItems {
                    try codeSign(item)
                }
            }
            try codeSign(appexURL)
            try codeSign(destURL)
        }

        // 8. Register
        registry.register(ExportRegistry.Entry(
            name: name,
            subtype: subtype,
            bundleId: bundleIdBase,
            exportDate: Date(),
            language: language.rawValue
        ))

        // 9. Validate exported bundle
        validateExportedBundle(at: destURL, language: language)

        log.info("Exported preset '\(name, privacy: .public)' as \(sanitized).app (subtype: \(subtype, privacy: .public))")
        return destURL
    }

    // MARK: - Pipeline Steps

    private func unzipTemplate(from zipURL: URL, to destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        // Unzip to a temp directory, then move the .app out
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-xk", zipURL.path, tempDir.path]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ExportError.copyFailed("Failed to unzip template: \(stderr)")
        }

        // The zip contains ConjureDSPExportAUTemplate.app at its root
        let unzippedApp = tempDir.appendingPathComponent("ConjureDSPExportAUTemplate.app")
        guard fm.fileExists(atPath: unzippedApp.path) else {
            throw ExportError.copyFailed("Unzipped template does not contain ConjureDSPExportAUTemplate.app")
        }
        do {
            try fm.moveItem(at: unzippedApp, to: destination)
        } catch {
            throw ExportError.copyFailed(error.localizedDescription)
        }
    }

    private func makeRuntimeConfig(
        name: String,
        language: ScriptLanguage,
        paramNames: [Int: String]?,
        paramMetadata: [ParamMetadata]? = nil,
        latencySamples: UInt32 = 0
    ) -> Data {
        var config: [String: Any] = [
            "version": 1,
            "language": language.rawValue,
            "presetName": name,
            "exportDate": ISO8601DateFormatter().string(from: Date()),
            "paramCount": 16,
        ]

        if latencySamples > 0 {
            config["latencySamples"] = latencySamples
        }

        // Include rich metadata if available (v2 format)
        if let metadata = paramMetadata, !metadata.isEmpty {
            let metaArray: [[String: Any]] = metadata.map { m in
                var dict: [String: Any] = [
                    "name": m.name,
                    "min": m.min,
                    "max": m.max,
                    "default": m.default,
                    "unit": m.unit,
                ]
                if let key = m.key { dict["key"] = key }
                if let curve = m.curve, curve != "linear" { dict["curve"] = curve }
                return dict
            }
            config["paramMetadata"] = metaArray
            config["paramCount"] = metadata.count
            // Also include paramNames for backward compat with older exported AU templates
            config["paramNames"] = metadata.map { $0.name }
        } else if let paramNames = paramNames, !paramNames.isEmpty {
            let maxIndex = paramNames.keys.max() ?? 0
            var namesArray: [String] = []
            for i in 0...maxIndex {
                namesArray.append(paramNames[i] ?? "Param \(i)")
            }
            config["paramNames"] = namesArray
            config["paramCount"] = namesArray.count
        }

        // swiftlint:disable:next force_try
        return try! JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
    }

    private func patchAppPlist(at url: URL, bundleId: String, displayName: String) throws {
        var plist = try loadPlist(at: url)
        plist["CFBundleIdentifier"] = bundleId
        plist["CFBundleName"] = displayName
        plist["CFBundleDisplayName"] = displayName
        try savePlist(plist, to: url)
    }

    private func patchExtensionPlist(
        at url: URL, bundleId: String, subtype: String, displayName: String
    ) throws {
        var plist = try loadPlist(at: url)
        plist["CFBundleIdentifier"] = bundleId
        plist["CFBundleDisplayName"] = displayName

        // Patch AudioComponents[0]
        guard var nsExt = plist["NSExtension"] as? [String: Any],
              var attrs = nsExt["NSExtensionAttributes"] as? [String: Any],
              var components = attrs["AudioComponents"] as? [[String: Any]],
              !components.isEmpty
        else {
            throw ExportError.plistPatchFailed("Missing AudioComponents in extension plist")
        }

        components[0]["subtype"] = subtype
        components[0]["name"] = "ConjureDSP: \(displayName)"
        components[0]["description"] = displayName

        attrs["AudioComponents"] = components
        nsExt["NSExtensionAttributes"] = attrs
        plist["NSExtension"] = nsExt

        try savePlist(plist, to: url)
    }

    // MARK: - Plist I/O

    private func loadPlist(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let plist = try PropertyListSerialization.propertyList(
            from: data, format: nil
        ) as? [String: Any] else {
            throw ExportError.plistPatchFailed("Plist is not a dictionary at \(url.lastPathComponent)")
        }
        return plist
    }

    private func savePlist(_ plist: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        )
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Code Signing

    private func codeSign(_ url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        // --preserve-metadata=entitlements: keeps the sandbox entitlements from the
        // Xcode-built template. Without this, ad-hoc signing strips entitlements and
        // PluginKit refuses to register the extension (requires app-sandbox = true).
        // No --deep: we sign in correct order (frameworks → appex → app) already.
        process.arguments = ["-s", "-", "--force", "--timestamp=none",
                             "--preserve-metadata=entitlements", url.path]

        let pipe = Pipe()
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let stderr = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ExportError.codeSignFailed(stderr)
        }
    }

    // MARK: - Post-Export Validation

    /// Validates the exported bundle contains a valid preset and runtime config.
    /// Logs warnings on failure rather than throwing — the export itself succeeded.
    private func validateExportedBundle(at appURL: URL, language: ScriptLanguage) {
        let appexResources = appURL
            .appendingPathComponent("Contents/PlugIns/ConjureDSPExportAUTemplateExtension.appex")
            .appendingPathComponent("Contents/Resources")
        let fm = FileManager.default

        // Check preset file exists and is non-empty
        let presetFile: URL
        switch language {
        case .rust:
            presetFile = appexResources.appendingPathComponent("preset.wasm")
        case .python:
            presetFile = appexResources.appendingPathComponent("preset.py")
        }

        guard fm.fileExists(atPath: presetFile.path) else {
            log.warning("Export validation: preset file missing at \(presetFile.lastPathComponent, privacy: .public)")
            return
        }

        guard let presetData = try? Data(contentsOf: presetFile), !presetData.isEmpty else {
            log.warning("Export validation: preset file is empty")
            return
        }

        // WASM: verify magic bytes (\0asm)
        if language == .rust {
            let wasmMagic: [UInt8] = [0x00, 0x61, 0x73, 0x6D]
            let header = [UInt8](presetData.prefix(4))
            if header != wasmMagic {
                log.warning("Export validation: WASM file missing magic bytes")
            }
        }

        // Python: verify contains process function
        if language == .python {
            if let source = String(data: presetData, encoding: .utf8), !source.contains("def process") {
                log.warning("Export validation: Python file missing 'def process'")
            }
        }

        // Check runtime-config.json exists and is valid JSON
        let configURL = appexResources.appendingPathComponent("runtime-config.json")
        if let configData = try? Data(contentsOf: configURL) {
            if (try? JSONSerialization.jsonObject(with: configData)) == nil {
                log.warning("Export validation: runtime-config.json is not valid JSON")
            }
        } else {
            log.warning("Export validation: runtime-config.json missing")
        }
    }

    // MARK: - Helpers

    /// Sanitizes a preset name for use as a bundle ID component and filesystem name.
    static func sanitizeName(_ name: String) -> String {
        // Keep only alphanumeric, hyphens, and underscores
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let sanitized = name.unicodeScalars
            .map { allowed.contains($0) ? String($0) : "_" }
            .joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return sanitized.isEmpty ? "Untitled" : sanitized
    }
}
