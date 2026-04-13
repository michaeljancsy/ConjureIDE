import CommonCrypto
import Foundation
import Testing

// =============================================================================
// Self-contained PersonalRepoSync tests. The gitBlobSHA function is copied
// from PersonalRepoSync.swift to avoid importing the extension target.
// =============================================================================

// MARK: - Copied gitBlobSHA

private func gitBlobSHA(for content: String) -> String {
    let data = Data(content.utf8)
    let header = "blob \(data.count)\0"
    var blob = Data(header.utf8)
    blob.append(data)

    var digest = [UInt8](repeating: 0, count: 20)
    blob.withUnsafeBytes { buffer in
        _ = CC_SHA1(buffer.baseAddress, CC_LONG(buffer.count), &digest)
    }
    return digest.map { String(format: "%02x", $0) }.joined()
}

// =============================================================================
// MARK: - Tests
// =============================================================================

@Suite("Git Blob SHA (PersonalRepoSync)")
struct PersonalRepoSyncTests {

    @Test func gitBlobSHAEmptyString() {
        // echo -n "" | git hash-object --stdin = e69de29bb2d1d6434b8b29ae775ad8c2e48c5391
        let sha = gitBlobSHA(for: "")
        #expect(sha == "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
    }

    @Test func gitBlobSHAKnownContent() {
        // echo -n "hello" | git hash-object --stdin = b6fc4c620b67d95f953a5c1c1230aaab5db5a1b0
        let sha = gitBlobSHA(for: "hello")
        #expect(sha == "b6fc4c620b67d95f953a5c1c1230aaab5db5a1b0")
    }

    @Test func gitBlobSHADifferentContentsDiffer() {
        let sha1 = gitBlobSHA(for: "foo")
        let sha2 = gitBlobSHA(for: "bar")
        #expect(sha1 != sha2)
    }

    @Test func gitBlobSHADeterministic() {
        let content = "def process(inputs, outputs, frame_count, sample_rate):\n    pass\n"
        let sha1 = gitBlobSHA(for: content)
        let sha2 = gitBlobSHA(for: content)
        #expect(sha1 == sha2)
    }
}
