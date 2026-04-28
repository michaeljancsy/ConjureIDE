//
//  String+Utils.swift
//  ConjureDSPExtension
//
//  Created by Michael Jancsy on 2/25/26.
//

import Foundation

extension String {
    var range: NSRange {
        NSRange(location: 0, length: count)
    }

    func isAlphanumeric() -> Bool {
        if self.isEmpty { return false }
        guard String.alphanumericRegex.firstMatch(in: self, options: [], range: range) != nil else {
            return false
        }
        return true
    }

    // Static regex — compiled once. fatalError on bad pattern is intentional:
    // this is a programmer error that should be caught at dev time.
    private static let alphanumericRegex: NSRegularExpression = {
        guard let re = try? NSRegularExpression(pattern: "^[a-zA-Z0-9_-]*$", options: .caseInsensitive) else {
            fatalError("String.alphanumericRegex: pattern is invalid")
        }
        return re
    }()
}
