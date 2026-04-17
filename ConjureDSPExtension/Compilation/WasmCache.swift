import CryptoKit
import Foundation
import os

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
        do {
            try wasm.write(to: file)
        } catch {
            Logger(subsystem: "com.MichaelJancsy.ConjureDSP", category: "WasmCache")
                .error("Failed to write WASM cache: \(error.localizedDescription, privacy: .public)")
            SentryHelper.captureError(error, category: "wasm.cache", extra: ["path": file.path, "size": wasm.count])
        }
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

    /// Returns the modification date of the conjuredsp rlib, if found.
    /// Checks the installed rustc language module first (Phase 3+ layout),
    /// then falls back to the bundled rustc-dist inside the extension. If
    /// neither exists, the rlib date contribution to the cache key is nil,
    /// which is fine: WasmCache just won't self-invalidate on rlib changes
    /// until a compiler becomes available.
    private func rlibModificationDate() -> Date? {
        let candidates: [String] = [
            LanguageModuleManager.moduleDirectory(for: "rustc")
                .appendingPathComponent("lib/libconjuredsp.rlib").path,
            (Bundle(for: WasmCache.self).resourcePath as NSString?)?
                .appendingPathComponent("rustc-dist/lib/libconjuredsp.rlib") ?? ""
        ]
        for path in candidates where !path.isEmpty {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
               let date = attrs[.modificationDate] as? Date {
                return date
            }
        }
        return nil
    }
}
