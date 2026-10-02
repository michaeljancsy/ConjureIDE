//
//  AtomicInstallTests.swift
//  ConjureDSPLogicTests
//
//  The plugin starts Python as soon as PythonRuntime/lib/python3.14t exists.
//  When the Terminal deleted that folder and copied a fresh one in its place,
//  a plugin opened during the copy started Python against a half-copied
//  stdlib; CPython then prints "Fatal Python error" and calls exit(1), which
//  kills the plugin process and leaves the host showing a blank view.
//  These tests pin that an installed item is never visible half-written.
//

import Foundation
import Testing

struct AtomicInstallTests {

    private let fm = FileManager.default

    /// Fresh scratch directory per test.
    private func makeScratch() throws -> URL {
        let url = fm.temporaryDirectory.appendingPathComponent("AtomicInstallTests-\(UUID().uuidString)")
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Creates a directory at `url` holding one small file per name.
    private func makeTree(at url: URL, files names: [String]) throws {
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        for name in names {
            try name.write(to: url.appendingPathComponent(name), atomically: false, encoding: .utf8)
        }
    }

    /// Sorted entry names, or nil when nothing exists at `url`.
    private func entries(of url: URL) -> [String]? {
        (try? fm.contentsOfDirectory(atPath: url.path))?.sorted()
    }

    /// Staging copies for `destination` still sitting in `parent`.
    private func stagingLeftovers(in parent: URL, for destination: URL) -> [String] {
        (entries(of: parent) ?? []).filter { $0.hasPrefix(AtomicInstall.stagingPrefix(for: destination)) }
    }

    /// Copies a directory one file at a time, calling `afterFirstFile` once
    /// the first file has landed, i.e. while the copy is still in progress.
    private func copyOneFileAtATime(afterFirstFile: @escaping () -> Void) -> (URL, URL) throws -> Void {
        return { [fm] src, dst in
            try fm.createDirectory(at: dst, withIntermediateDirectories: false)
            for (i, name) in try fm.contentsOfDirectory(atPath: src.path).sorted().enumerated() {
                try fm.copyItem(at: src.appendingPathComponent(name), to: dst.appendingPathComponent(name))
                if i == 0 { afterFirstFile() }
            }
        }
    }

    @Test("First install: destination stays absent until the copy is complete")
    func firstInstallNeverVisiblePartial() throws {
        let root = try makeScratch()
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try makeTree(at: source, files: ["a.py", "b.py", "c.py"])
        let destination = root.appendingPathComponent("lib/python3.14t")
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        var midCopy: [String]?? = .none
        try AtomicInstall.replaceItem(
            at: destination,
            withCopyOf: source,
            copy: copyOneFileAtATime { midCopy = .some(entries(of: destination)) }
        )

        #expect(midCopy == .some(nil), "destination was visible mid-copy with \(String(describing: midCopy))")
        #expect(entries(of: destination) == ["a.py", "b.py", "c.py"])
    }

    @Test("Reinstall: destination keeps the old complete copy until the new one is complete")
    func reinstallNeverVisiblePartial() throws {
        let root = try makeScratch()
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try makeTree(at: source, files: ["a.py", "b.py", "c.py"])
        let destination = root.appendingPathComponent("python3.14t")
        try makeTree(at: destination, files: ["old1.py", "old2.py"])

        var midCopy: [String]?? = .none
        try AtomicInstall.replaceItem(
            at: destination,
            withCopyOf: source,
            copy: copyOneFileAtATime { midCopy = .some(entries(of: destination)) }
        )

        #expect(midCopy == .some(["old1.py", "old2.py"]), "destination mid-copy was \(String(describing: midCopy))")
        #expect(entries(of: destination) == ["a.py", "b.py", "c.py"])
    }

    @Test("A failed copy leaves the existing install untouched and no staging copy behind")
    func failedCopyKeepsExistingInstall() throws {
        struct CopyFailed: Error {}
        let root = try makeScratch()
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try makeTree(at: source, files: ["a.py", "b.py"])
        let parent = root.appendingPathComponent("lib")
        let destination = parent.appendingPathComponent("python3.14t")
        try makeTree(at: destination, files: ["old1.py"])

        let failingCopy: (URL, URL) throws -> Void = { [fm] src, dst in
            try fm.createDirectory(at: dst, withIntermediateDirectories: false)
            try fm.copyItem(at: src.appendingPathComponent("a.py"), to: dst.appendingPathComponent("a.py"))
            throw CopyFailed()
        }
        #expect(throws: CopyFailed.self) {
            try AtomicInstall.replaceItem(at: destination, withCopyOf: source, copy: failingCopy)
        }

        #expect(entries(of: destination) == ["old1.py"])
        #expect(stagingLeftovers(in: parent, for: destination).isEmpty)
    }

    @Test("Leaves no staging copy behind, on first install and on reinstall")
    func noStagingLeftovers() throws {
        let root = try makeScratch()
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try makeTree(at: source, files: ["a.py"])
        let parent = root.appendingPathComponent("site-packages")
        let destination = parent.appendingPathComponent("conjuredsp")
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)

        try AtomicInstall.replaceItem(at: destination, withCopyOf: source)
        #expect(stagingLeftovers(in: parent, for: destination).isEmpty)

        try AtomicInstall.replaceItem(at: destination, withCopyOf: source)
        #expect(stagingLeftovers(in: parent, for: destination).isEmpty)
        #expect(entries(of: destination) == ["a.py"])
    }

    @Test("Clears a staging copy left by an install that was interrupted")
    func clearsInterruptedStaging() throws {
        let root = try makeScratch()
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try makeTree(at: source, files: ["a.py"])
        let parent = root.appendingPathComponent("lib")
        let destination = parent.appendingPathComponent("python3.14t")
        try makeTree(at: parent.appendingPathComponent(AtomicInstall.stagingPrefix(for: destination) + "-interrupted"), files: ["half.py"])

        try AtomicInstall.replaceItem(at: destination, withCopyOf: source)

        #expect(stagingLeftovers(in: parent, for: destination).isEmpty)
        #expect(entries(of: destination) == ["a.py"])
    }

    @Test("A leftover staging copy that can't be removed doesn't block the install")
    func undeletableLeftoverDoesNotBlock() throws {
        let root = try makeScratch()
        let source = root.appendingPathComponent("source")
        try makeTree(at: source, files: ["a.py"])
        let parent = root.appendingPathComponent("lib")
        let destination = parent.appendingPathComponent("python3.14t")
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        // A read-only folder can't have its contents deleted, so neither can it.
        let leftover = parent.appendingPathComponent(AtomicInstall.stagingPrefix(for: destination) + "-interrupted")
        try makeTree(at: leftover, files: ["half.py"])
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: leftover.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: leftover.path)
            try? fm.removeItem(at: root)
        }

        try AtomicInstall.replaceItem(at: destination, withCopyOf: source)

        #expect(entries(of: destination) == ["a.py"])
    }

    @Test("Two installers at once: neither clears the other's in-progress copy")
    func concurrentInstallsDoNotInterfere() throws {
        final class Outcome: @unchecked Sendable { var error: Error? }
        let root = try makeScratch()
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try makeTree(at: source, files: ["a.py", "b.py", "c.py"])
        let destination = root.appendingPathComponent("python3.14t")

        // A second installer starts while the first is mid-copy, the way a
        // Debug and a Release Terminal launched together would.
        let second = Outcome()
        let group = DispatchGroup()
        try AtomicInstall.replaceItem(
            at: destination,
            withCopyOf: source,
            copy: copyOneFileAtATime {
                DispatchQueue.global().async(group: group) {
                    do { try AtomicInstall.replaceItem(at: destination, withCopyOf: source) }
                    catch { second.error = error }
                }
                Thread.sleep(forTimeInterval: 0.3)  // time for the second installer's cleanup to run
            }
        )

        #expect(group.wait(timeout: .now() + 10) == .success)
        #expect(second.error == nil)
        #expect(entries(of: destination) == ["a.py", "b.py", "c.py"])
    }

    @Test("Replaces a single file (libpython, the python3 launcher)")
    func replacesSingleFile() throws {
        let root = try makeScratch()
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("new.dylib")
        try "new".write(to: source, atomically: false, encoding: .utf8)
        let destination = root.appendingPathComponent("libpython3.14t.dylib")
        try "old".write(to: destination, atomically: false, encoding: .utf8)

        try AtomicInstall.replaceItem(at: destination, withCopyOf: source)

        #expect(try String(contentsOf: destination, encoding: .utf8) == "new")
    }
}
