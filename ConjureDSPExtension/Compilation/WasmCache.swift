import CryptoKit
import Foundation

/// Caches compiled WASM binaries by SHA256 hash of source code.
final class WasmCache {
    let cacheDir: URL

    init() {
        cacheDir =
            AppGroupContainer.url
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
        var combined = string + (depsHash ?? "")
        // Include the rlib modification time so cache invalidates when the
        // conjuredsp library changes (e.g., new nam!() macro, new accel ops).
        if let rlibDate = rlibModificationDate() {
            combined += "\(rlibDate.timeIntervalSince1970)"
        }
        let digest = SHA256.hash(data: Data(combined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Returns the modification date of the bundled conjuredsp rlib, if found.
    private func rlibModificationDate() -> Date? {
        guard let resourcePath = Bundle(for: WasmCache.self).resourcePath else { return nil }
        let rlibPath = (resourcePath as NSString)
            .appendingPathComponent("rustc-dist/lib/libconjuredsp.rlib")
        return (try? FileManager.default.attributesOfItem(atPath: rlibPath))?[.modificationDate] as? Date
    }
}
