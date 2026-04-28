//
//  PTYManagerBuildCStringArrayTests.swift
//  ConjureDSPTerminalTests
//
//  Tests for PTYManager.buildCStringArray(_:dupFn:) — the null-check paths
//  that guard against strdup failure cannot be triggered without DI, so we
//  inject a controlled dupFn.
//

import Testing
import Foundation
@testable import ConjureDSPTerminal

struct PTYManagerBuildCStringArrayTests {

    // MARK: - Happy paths

    @Test func allStringsSucceed_returnsArrayWithSentinel() throws {
        let strings = ["hello", "world", "foo"]
        let result = PTYManager.buildCStringArray(strings)

        let array = try #require(result, "Expected non-nil result when all dups succeed")
        // Should have count + 1 entries (nil sentinel)
        #expect(array.count == strings.count + 1)
        // Last entry must be the nil sentinel
        #expect(array.last! == nil)
        // Content should match
        for (i, s) in strings.enumerated() {
            let cstr = try #require(array[i], "Entry \(i) should not be nil")
            #expect(String(cString: cstr) == s)
        }
        // Free the allocated strings
        array.forEach { if let p = $0 { free(p) } }
    }

    @Test func emptyInput_returnsSentinelOnly() throws {
        let result = PTYManager.buildCStringArray([])

        let array = try #require(result, "Expected non-nil result for empty input")
        #expect(array.count == 1)
        #expect(array[0] == nil)
    }

    @Test func singleString_returnsEntryPlusSentinel() throws {
        let result = PTYManager.buildCStringArray(["only"])

        let array = try #require(result, "Expected non-nil result for single string")
        #expect(array.count == 2)
        let cstr = try #require(array[0])
        #expect(String(cString: cstr) == "only")
        #expect(array[1] == nil)
        free(array[0])
    }

    // MARK: - Failure paths (injected dupFn)

    @Test func dupFailsOnFirstCall_returnsNil() {
        // dupFn always returns nil — simulates total strdup failure
        let result = PTYManager.buildCStringArray(["a", "b", "c"]) { _ in nil }
        #expect(result == nil)
    }

    @Test func dupFailsOnSecondCall_returnsNil() {
        // dupFn succeeds once, then fails — tests that the first allocation is freed
        // and nil is returned without a crash.
        var callCount = 0
        let result = PTYManager.buildCStringArray(["first", "second", "third"]) { s in
            callCount += 1
            if callCount == 2 { return nil }
            return strdup(s)
        }
        #expect(result == nil)
        #expect(callCount == 2)
    }

    @Test func dupFailsOnLastCall_returnsNil() {
        // dupFn fails only on the last string — tests partial-free path.
        let strings = ["x", "y", "z"]
        var callCount = 0
        let result = PTYManager.buildCStringArray(strings) { s in
            callCount += 1
            if callCount == strings.count { return nil }
            return strdup(s)
        }
        #expect(result == nil)
        #expect(callCount == strings.count)
    }

    // MARK: - String fidelity

    @Test func stringsWithSpecialCharacters_roundTrip() throws {
        let strings = ["PATH=/usr/bin:/bin", "HOME=/Users/test", "LANG=en_US.UTF-8"]
        let result = PTYManager.buildCStringArray(strings)

        let array = try #require(result)
        for (i, s) in strings.enumerated() {
            let cstr = try #require(array[i])
            #expect(String(cString: cstr) == s)
        }
        array.forEach { if let p = $0 { free(p) } }
    }
}
