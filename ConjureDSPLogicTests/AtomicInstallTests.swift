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

    @Test("A failed copy leaves the existing install untouched and nothing else behind")
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
        #expect(entries(of: parent) == ["python3.14t"])
    }

    @Test("Leaves only the installed item in the parent folder, on first install and on reinstall")
    func noStagingLeftovers() throws {
        let root = try makeScratch()
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try makeTree(at: source, files: ["a.py"])
        let parent = root.appendingPathComponent("site-packages")
        let destination = parent.appendingPathComponent("conjuredsp")
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)

        try AtomicInstall.replaceItem(at: destination, withCopyOf: source)
        #expect(entries(of: parent) == ["conjuredsp"])

        try AtomicInstall.replaceItem(at: destination, withCopyOf: source)
        #expect(entries(of: parent) == ["conjuredsp"])
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
        try makeTree(at: AtomicInstall.stagingURL(for: destination), files: ["half.py"])

        try AtomicInstall.replaceItem(at: destination, withCopyOf: source)

        #expect(entries(of: parent) == ["python3.14t"])
        #expect(entries(of: destination) == ["a.py"])
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
