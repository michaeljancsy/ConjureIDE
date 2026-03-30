import CryptoKit
import Foundation

/// Caches compiled WASM binaries by SHA256 hash of source code.
final class WasmCache {
    let cacheDir: URL

    init() {
        let appSupport =
            FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        cacheDir =
            appSupport
            .appendingPathComponent("ConjureDSP", isDirectory: true)
            .appendingPathComponent("WasmCache", isDirectory: true)

        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    /// Returns cached WASM bytes for the given source, or nil on cache miss.
    /// Pass `depsHash` for Rust scripts to incorporate installed crate versions into the key.
    func cachedWasm(for source: String, depsHash: String? = nil) -> Data? {
        let file = cacheDir.appendingPathComponent("\(hash(source, depsHash: depsHash)).wasm")
        return try? Data(contentsOf: file)
    }

    /// Stores compiled WASM bytes keyed by source hash.
    /// Pass `depsHash` for Rust scripts to incorporate installed crate versions into the key.
    func cache(wasm: Data, for source: String, depsHash: String? = nil) {
        let file = cacheDir.appendingPathComponent("\(hash(source, depsHash: depsHash)).wasm")
        try? wasm.write(to: file)
    }

    private func hash(_ string: String, depsHash: String? = nil) -> String {
        let combined = string + (depsHash ?? "")
        let digest = SHA256.hash(data: Data(combined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
