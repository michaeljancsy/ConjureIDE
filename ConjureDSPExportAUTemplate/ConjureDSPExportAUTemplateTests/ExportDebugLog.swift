//
//  ExportDebugLog.swift
//  ConjureDSPExportAUTemplateTests
//
//  Copy of ExportDebugLog from ConjureDSPExportAUTemplateExtension for unit
//  testing. The AU extension target can't be @testable-imported because it's
//  an appex, so the test target compiles its own copy.
//

import Foundation
import SwiftUI

/// Main-thread only by discipline (enforced in debug builds via
/// `dispatchPrecondition`). Not `@MainActor`-isolated because it's constructed
/// during AU init which is called synchronously from `DispatchQueue.main.sync`
/// by the view controller factory — Swift's MainActor checker doesn't see
/// that as MainActor context, so the annotation blocks the init site.
final class ExportDebugLog: ObservableObject, @unchecked Sendable {
    enum Level: Int, Sendable {
        case debug
        case info
        case warning
        case error

        var tag: String {
            switch self {
            case .debug:   return "debug"
            case .info:    return "info"
            case .warning: return "warn"
            case .error:   return "error"
            }
        }
    }

    struct Entry: Identifiable, Sendable {
        let id: UInt64
        let timestamp: Date
        let level: Level
        let category: String
        let message: String
    }

    /// Maximum number of entries retained. Oldest are evicted when full.
    static let capacity = 10_000

    @Published private(set) var entries: [Entry] = []

    private var nextId: UInt64 = 0

    init() {
        entries.reserveCapacity(Self.capacity)
    }

    /// Append a new entry. Main-thread only.
    func append(level: Level, category: String, message: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        let entry = Entry(
            id: nextId,
            timestamp: Date(),
            level: level,
            category: category,
            message: message
        )
        nextId &+= 1
        if entries.count >= Self.capacity {
            // Drop oldest. Array.removeFirst is O(n) but at 10k entries this
            // happens at most once per line after we've been running a long
            // time — acceptable for debug-only UI.
            entries.removeFirst()
        }
        entries.append(entry)
    }

    /// Clear all entries. Main-thread only.
    func clear() {
        dispatchPrecondition(condition: .onQueue(.main))
        entries.removeAll(keepingCapacity: true)
    }

    /// Return a plain-text representation suitable for copying to the clipboard.
    /// Format: `[HH:mm:ss.SSS] [level] [category] message` per line.
    func formattedForCopy() -> String {
        dispatchPrecondition(condition: .onQueue(.main))
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        var lines: [String] = []
        lines.reserveCapacity(entries.count)
        for entry in entries {
            let ts = formatter.string(from: entry.timestamp)
            lines.append("[\(ts)] [\(entry.level.tag)] [\(entry.category)] \(entry.message)")
        }
        return lines.joined(separator: "\n")
    }
}
