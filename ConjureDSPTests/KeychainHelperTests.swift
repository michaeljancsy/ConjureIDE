import Foundation
import Security
import Testing

// =============================================================================
// Self-contained KeychainHelper tests. Uses a unique service name per test run
// to avoid conflicts with the real app keychain or other test runs.
// =============================================================================

// MARK: - Test Keychain Helper

private enum TestKeychainHelper {
    static let service = "com.MichaelJancsy.ConjureDSP.Tests.\(UUID().uuidString)"

    static func save(key: String, value: String) throws {
        guard let data = value.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        // Delete existing item first, then add
        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = data

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// =============================================================================
// MARK: - Tests
// =============================================================================

@Suite("KeychainHelper")
struct KeychainHelperTests {

    @Test func saveThenLoadReturnsValue() throws {
        let key = "test-key-\(UUID().uuidString)"
        defer { TestKeychainHelper.delete(key: key) }

        try TestKeychainHelper.save(key: key, value: "secret-token")
        let loaded = TestKeychainHelper.load(key: key)
        #expect(loaded == "secret-token")
    }

    @Test func loadNonexistentReturnsNil() {
        let key = "nonexistent-key-\(UUID().uuidString)"
        let loaded = TestKeychainHelper.load(key: key)
        #expect(loaded == nil)
    }

    @Test func saveOverwriteReturnsNewValue() throws {
        let key = "overwrite-key-\(UUID().uuidString)"
        defer { TestKeychainHelper.delete(key: key) }

        try TestKeychainHelper.save(key: key, value: "original")
        try TestKeychainHelper.save(key: key, value: "updated")
        let loaded = TestKeychainHelper.load(key: key)
        #expect(loaded == "updated")
    }

    @Test func deleteThenLoadReturnsNil() throws {
        let key = "delete-key-\(UUID().uuidString)"

        try TestKeychainHelper.save(key: key, value: "to-be-deleted")
        TestKeychainHelper.delete(key: key)
        let loaded = TestKeychainHelper.load(key: key)
        #expect(loaded == nil)
    }

    @Test func saveEmptyStringWorks() throws {
        let key = "empty-key-\(UUID().uuidString)"
        defer { TestKeychainHelper.delete(key: key) }

        try TestKeychainHelper.save(key: key, value: "")
        let loaded = TestKeychainHelper.load(key: key)
        #expect(loaded == "")
    }
}
