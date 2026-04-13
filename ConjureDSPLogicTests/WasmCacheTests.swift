import CryptoKit
import Foundation
import Testing

// =============================================================================
// Self-contained WASM cache tests. Uses a temp directory instead of App Support
// to avoid polluting the real cache.
// =============================================================================

// MARK: - Test WASM Cache

private final class TestWasmCache {
    let cacheDir: URL

    init() {
        cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConjureDSPTests-WasmCache-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: cacheDir)
    }

    func cachedWasm(for source: String) -> Data? {
        let file = cacheDir.appendingPathComponent("\(hash(source)).wasm")
        return try? Data(contentsOf: file)
    }

    func cache(wasm: Data, for source: String) {
        let file = cacheDir.appendingPathComponent("\(hash(source)).wasm")
        try? wasm.write(to: file)
    }

    func hash(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// =============================================================================
// MARK: - Tests
// =============================================================================

@Suite("WasmCache")
struct WasmCacheTests {

    @Test func cacheMissReturnsNil() {
        let cache = TestWasmCache()
        let result = cache.cachedWasm(for: "fn process() {}")
        #expect(result == nil)
    }

    @Test func cacheHitReturnsStoredData() {
        let cache = TestWasmCache()
        let wasmData = Data("fake wasm binary".utf8)
        let source = "fn process() { /* v1 */ }"

        cache.cache(wasm: wasmData, for: source)
        let result = cache.cachedWasm(for: source)

        #expect(result == wasmData)
    }

    @Test func differentSourceReturnsDifferentData() {
        let cache = TestWasmCache()
        let wasm1 = Data("wasm-v1".utf8)
        let wasm2 = Data("wasm-v2".utf8)

        cache.cache(wasm: wasm1, for: "source A")
        cache.cache(wasm: wasm2, for: "source B")

        #expect(cache.cachedWasm(for: "source A") == wasm1)
        #expect(cache.cachedWasm(for: "source B") == wasm2)
    }

    @Test func sameSourceReturnsSameData() {
        let cache = TestWasmCache()
        let wasmData = Data("compiled output".utf8)
        let source = "fn process() {}"

        cache.cache(wasm: wasmData, for: source)

        // Retrieve twice — both should return the same data
        let first = cache.cachedWasm(for: source)
        let second = cache.cachedWasm(for: source)
        #expect(first == second)
        #expect(first == wasmData)
    }

    @Test func hashIsDeterministic() {
        let cache = TestWasmCache()
        let source = "fn process() { /* deterministic test */ }"

        let hash1 = cache.hash(source)
        let hash2 = cache.hash(source)

        #expect(hash1 == hash2)
        #expect(hash1.count == 64) // SHA256 hex = 64 chars
    }
}
