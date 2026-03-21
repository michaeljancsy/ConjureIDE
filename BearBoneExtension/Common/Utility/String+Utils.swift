//
//  String+Utils.swift
//  BearBoneExtension
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
        let regex = try! NSRegularExpression(pattern: "^[a-zA-Z0-9_-]*$", options: .caseInsensitive)
        guard regex.firstMatch(in: self, options: [], range: range) != nil else {
            return false
        }
        return true
    }

    /// Strips leading markdown code fences (e.g. ```python) and trailing ``` from AI responses.
    func strippingCodeFences() -> String {
        var result = self
        // Strip leading ```<language>\n or ```\n
        if let range = result.range(of: #"^\s*```\w*\n?"#, options: .regularExpression) {
            result.removeSubrange(range)
        }
        // Strip trailing \n```
        if let range = result.range(of: #"\n?```\s*$"#, options: .regularExpression) {
            result.removeSubrange(range)
        }
        return result
    }
}
