import Foundation
import Testing

// Self-contained copy of strippingCodeFences() to avoid duplicate symbol
// issues when the AU extension is loaded in-process during testing.
private extension String {
    func strippingCodeFences() -> String {
        var result = self
        if let range = result.range(of: #"^\s*```\w*\n?"#, options: .regularExpression) {
            result.removeSubrange(range)
        }
        if let range = result.range(of: #"\n?```\s*$"#, options: .regularExpression) {
            result.removeSubrange(range)
        }
        return result
    }
}

struct StringUtilsTests {

    @Test func strippingCodeFences_alreadyClean() {
        let code = "import numpy as np\n\ndef process():\n    pass"
        #expect(code.strippingCodeFences() == code)
    }

    @Test func strippingCodeFences_pythonFence() {
        let input = "```python\nimport numpy as np\n\ndef process():\n    pass\n```"
        let expected = "import numpy as np\n\ndef process():\n    pass"
        #expect(input.strippingCodeFences() == expected)
    }

    @Test func strippingCodeFences_rustFence() {
        let input = "```rust\nfn process() {}\n```"
        let expected = "fn process() {}"
        #expect(input.strippingCodeFences() == expected)
    }

    @Test func strippingCodeFences_plainFence() {
        let input = "```\nimport numpy as np\n```"
        let expected = "import numpy as np"
        #expect(input.strippingCodeFences() == expected)
    }

    @Test func strippingCodeFences_noTrailingNewline() {
        let input = "```python\ncode here```"
        let expected = "code here"
        #expect(input.strippingCodeFences() == expected)
    }
}
