//
//  FactoryWasmSidecar.swift
//  ConjureDSPExtension
//
//  Looks up pre-compiled WASM for factory Rust presets. The release build
//  pipeline (scripts/build-factory-wasm.sh) produces a .wasm file per factory
//  preset, named by the SHA256 of its .rs source, and bundles them under
//  Resources/factory-wasm/ in the extension .appex.
//
//  At runtime, when the audio-unit load path receives a Rust source string,
//  it asks the sidecar for a match before touching the live RustCompiler /
//  WasmCache path. A match means "unmodified factory source" → play directly.
//  A miss (source was user-edited, or the preset didn't ship with a sidecar)
//  falls through to the live compile path, which still works in Debug and will
//  require the rustc language module once it's stripped from the bundle.
//

import CryptoKit
import Foundation

enum FactoryWasmSidecar {

    /// Directory inside the extension bundle where sidecars live. `nil` if the
    /// bundle was built without the "Build Factory WASM Sidecars" phase (e.g.
    /// a partial Debug build that skipped it).
    static func sidecarDirectory() -> URL? {
        guard let resourcePath = Bundle.main.resourcePath else {
            // `Bundle.main` in an AU extension is the extension bundle itself
            // when loaded by PluginKit, but when unit tests instantiate this
            // type directly it's the test bundle. Fall back to the bundle that
            // owns this class.
            return classBundleSidecarDirectory()
        }
        let candidate = URL(fileURLWithPath: resourcePath)
            .appendingPathComponent("factory-wasm", isDirectory: true)
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        return classBundleSidecarDirectory()
    }

    private static func classBundleSidecarDirectory() -> URL? {
        let bundle = Bundle(for: SidecarLookupAnchor.self)
        guard let resourcePath = bundle.resourcePath else { return nil }
        let candidate = URL(fileURLWithPath: resourcePath)
            .appendingPathComponent("factory-wasm", isDirectory: true)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// Returns pre-compiled WASM bytes if `source` matches a factory preset
    /// sidecar, or `nil` otherwise. Computes SHA256 of the UTF-8 source bytes
    /// and looks for `<sidecar-dir>/<sha256-hex>.wasm`.
    static func wasm(forSource source: String) -> Data? {
        wasm(forSource: source, sidecarDirectory: sidecarDirectory())
    }

    /// Testing seam: takes an explicit sidecar directory rather than resolving
    /// it from the bundle.
    static func wasm(forSource source: String, sidecarDirectory: URL?) -> Data? {
        guard let directory = sidecarDirectory else { return nil }
        let hash = sha256Hex(of: source)
        let fileURL = directory.appendingPathComponent("\(hash).wasm")
        return try? Data(contentsOf: fileURL)
    }

    /// SHA256 of `source` as UTF-8, lowercase hex. Matches the naming scheme
    /// used by `scripts/build-factory-wasm.sh`.
    static func sha256Hex(of source: String) -> String {
        let digest = SHA256.hash(data: Data(source.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Anchor type for locating the Swift bundle containing this class.
    /// Needed because `Bundle(for:)` on an `enum` crashes at runtime.
    private final class SidecarLookupAnchor {}
}
