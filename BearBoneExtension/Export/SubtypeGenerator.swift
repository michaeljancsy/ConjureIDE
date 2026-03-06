import CryptoKit
import Foundation

/// Generates unique 4-character AU subtype codes from preset names.
enum SubtypeGenerator {
    /// Subtypes reserved by BearBone and the export template.
    static let reserved: Set<String> = ["0001", "WT01", "TMPL"]

    /// Characters allowed in AU subtype codes (printable ASCII, uppercase + digits).
    private static let alphabet: [Character] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")

    /// Generates a 4-character AU subtype code for the given preset name.
    ///
    /// The code is derived from a SHA256 hash of the name, mapped to uppercase
    /// alphanumeric characters. If the generated code collides with an existing
    /// or reserved subtype, the last character is incremented until unique.
    static func generate(for presetName: String, existing: Set<String>) -> String {
        let digest = SHA256.hash(data: Data(presetName.utf8))
        let bytes = Array(digest)

        // Map first 4 hash bytes to alphabet characters
        var chars = (0..<4).map { i in
            alphabet[Int(bytes[i]) % alphabet.count]
        }

        var code = String(chars)

        // Resolve collisions by incrementing the last character
        let allReserved = reserved.union(existing)
        while allReserved.contains(code) {
            chars[3] = nextChar(chars[3])
            code = String(chars)
        }

        return code
    }

    /// Returns the next character in the alphabet, wrapping around.
    private static func nextChar(_ c: Character) -> Character {
        guard let idx = alphabet.firstIndex(of: c) else { return alphabet[0] }
        return alphabet[(alphabet.distance(from: alphabet.startIndex, to: idx) + 1) % alphabet.count]
    }
}
