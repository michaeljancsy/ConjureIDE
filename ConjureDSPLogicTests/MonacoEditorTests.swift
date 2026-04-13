import Foundation
import Testing

/// Tests for Monaco editor behavior patterns.
/// These test the logic patterns used in MonacoEditorView without requiring
/// SwiftUI view instantiation.

@Suite("Monaco Editor Patterns")
struct MonacoEditorPatternTests {

    @Test("Snippet insertion resets state synchronously to prevent duplication")
    func snippetResetPreventsduplication() {
        // Simulates the fix for the snippet duplication race condition.
        // The old code used DispatchQueue.main.async to reset, which allowed
        // SwiftUI to call updateNSView again before the reset executed.
        var snippetToInsert: String? = "console.log('hello')"
        var insertionCount = 0

        // Simulate two rapid updateNSView calls (SwiftUI reconciliation)
        for _ in 0..<2 {
            if let snippet = snippetToInsert {
                // Fix: reset BEFORE the JS call, not after
                snippetToInsert = nil
                // Simulate JS evaluation
                _ = snippet // would call evaluateJavaScript
                insertionCount += 1
            }
        }

        #expect(insertionCount == 1, "Snippet should only be inserted once")
        #expect(snippetToInsert == nil, "Snippet state should be cleared")
    }

    @Test("Snippet reset with async pattern allows duplication (demonstrates the bug)")
    func snippetAsyncResetAllowsDuplication() {
        // Demonstrates why the async reset was wrong.
        var snippetToInsert: String? = "console.log('hello')"
        var insertionCount = 0

        // Simulate two rapid updateNSView calls WITHOUT synchronous reset
        for _ in 0..<2 {
            if snippetToInsert != nil {
                insertionCount += 1
                // Old bug: reset was async, so snippetToInsert is still non-nil
                // for the next iteration
            }
        }
        // Only reset after both iterations (simulating async dispatch)
        snippetToInsert = nil

        #expect(insertionCount == 2, "Without sync reset, snippet inserts twice")
    }
}
