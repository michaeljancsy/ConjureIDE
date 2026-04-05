//
//  ExportDebugLogTests.swift
//  ConjureDSPExportAUTemplateTests
//

import Foundation
import Testing

@Suite("ExportDebugLog")
@MainActor
struct ExportDebugLogTests {
    @Test("append records entries in order")
    func appendInOrder() async {
        let log = ExportDebugLog()
        log.append(level: .info, category: "a", message: "first")
        log.append(level: .warning, category: "b", message: "second")
        log.append(level: .error, category: "c", message: "third")

        #expect(log.entries.count == 3)
        #expect(log.entries[0].message == "first")
        #expect(log.entries[0].level == .info)
        #expect(log.entries[0].category == "a")
        #expect(log.entries[1].message == "second")
        #expect(log.entries[1].level == .warning)
        #expect(log.entries[2].message == "third")
        #expect(log.entries[2].level == .error)
    }

    @Test("append enforces capacity by dropping oldest")
    func boundedEviction() async {
        let log = ExportDebugLog()
        let over = ExportDebugLog.capacity + 50
        for i in 0..<over {
            log.append(level: .info, category: "c", message: "m\(i)")
        }
        #expect(log.entries.count == ExportDebugLog.capacity)
        // Oldest 50 should have been dropped.
        #expect(log.entries.first?.message == "m50")
        #expect(log.entries.last?.message == "m\(over - 1)")
    }

    @Test("clear removes all entries")
    func clear() async {
        let log = ExportDebugLog()
        log.append(level: .info, category: "c", message: "x")
        log.append(level: .info, category: "c", message: "y")
        #expect(log.entries.count == 2)
        log.clear()
        #expect(log.entries.isEmpty)
    }

    @Test("entry ids are unique and monotonically increasing")
    func uniqueIds() async {
        let log = ExportDebugLog()
        for i in 0..<100 {
            log.append(level: .info, category: "c", message: "m\(i)")
        }
        let ids = log.entries.map { $0.id }
        #expect(Set(ids).count == ids.count)
        for i in 1..<ids.count {
            #expect(ids[i] > ids[i - 1])
        }
    }

    @Test("formattedForCopy produces one line per entry")
    func formattedForCopy() async {
        let log = ExportDebugLog()
        log.append(level: .info, category: "cat", message: "hello")
        log.append(level: .error, category: "boom", message: "bad thing")
        let text = log.formattedForCopy()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 2)
        #expect(lines[0].contains("[info]"))
        #expect(lines[0].contains("[cat]"))
        #expect(lines[0].contains("hello"))
        #expect(lines[1].contains("[error]"))
        #expect(lines[1].contains("[boom]"))
        #expect(lines[1].contains("bad thing"))
    }
}
