//
//  PythonStdlibProvisioningTests.swift
//  ConjureDSPTerminalTests
//
//  Regression guard for the non-destructive Python stdlib provisioning.
//  Before the fix, every source switch wiped `lib/python3.14t/site-packages/`
//  including user-installed packages. These tests lock in the contract:
//  user packages survive, bundled packages get cleanly updated, stdlib is
//  fully replaced.
//

import Foundation
import Testing
@testable import ConjureDSPTerminal

@Suite("Python stdlib provisioning (non-destructive)")
struct PythonStdlibProvisioningTests {

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("StdlibProvTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.data(using: .utf8)!.write(to: url)
    }

    private func read(_ url: URL) -> String? {
        (try? String(contentsOf: url, encoding: .utf8))
    }

    // MARK: - mergeSitePackages

    @Test("User packages survive a re-provision that updates bundled packages")
    func userPackagesSurviveReprovision() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let source = tmp.appendingPathComponent("source-site-packages")
        let dest = tmp.appendingPathComponent("dest-site-packages")

        // Source: new bundled numpy, new conjuredsp.
        try write("numpy 2.4.4", to: source.appendingPathComponent("numpy/__init__.py"))
        try write("def foo(): pass", to: source.appendingPathComponent("conjuredsp/__init__.py"))

        // Destination: OLD bundled numpy, OLD conjuredsp, AND user-installed librosa.
        try write("numpy 2.3.0 (old)", to: dest.appendingPathComponent("numpy/__init__.py"))
        try write("def foo_old(): pass", to: dest.appendingPathComponent("conjuredsp/__init__.py"))
        try write("# user installed", to: dest.appendingPathComponent("librosa/__init__.py"))
        try write("# also user", to: dest.appendingPathComponent("pedalboard/__init__.py"))

        try TerminalAppServer.mergeSitePackages(from: source, to: dest)

        // Bundled packages updated to source version.
        #expect(read(dest.appendingPathComponent("numpy/__init__.py")) == "numpy 2.4.4")
        #expect(read(dest.appendingPathComponent("conjuredsp/__init__.py")) == "def foo(): pass")

        // User packages preserved.
        #expect(read(dest.appendingPathComponent("librosa/__init__.py")) == "# user installed")
        #expect(read(dest.appendingPathComponent("pedalboard/__init__.py")) == "# also user")
    }

    @Test("Source directory fully replaces destination directory of same name")
    func sourceDirectoryFullyReplacesDestination() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let source = tmp.appendingPathComponent("source")
        let dest = tmp.appendingPathComponent("dest")

        // Source: conjuredsp with files A and B.
        try write("a new", to: source.appendingPathComponent("conjuredsp/a.py"))
        try write("b new", to: source.appendingPathComponent("conjuredsp/b.py"))

        // Destination: conjuredsp with files A (old) and C (removed in new version).
        try write("a old", to: dest.appendingPathComponent("conjuredsp/a.py"))
        try write("c old", to: dest.appendingPathComponent("conjuredsp/c.py"))

        try TerminalAppServer.mergeSitePackages(from: source, to: dest)

        // A updated, B added, C removed (the whole conjuredsp dir was replaced).
        #expect(read(dest.appendingPathComponent("conjuredsp/a.py")) == "a new")
        #expect(read(dest.appendingPathComponent("conjuredsp/b.py")) == "b new")
        #expect(!FileManager.default.fileExists(
            atPath: dest.appendingPathComponent("conjuredsp/c.py").path
        ))
    }

    @Test("Merge into empty destination behaves like full copy")
    func mergeIntoEmptyDestinationWorks() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let source = tmp.appendingPathComponent("source")
        let dest = tmp.appendingPathComponent("dest")  // doesn't exist yet
        try write("numpy", to: source.appendingPathComponent("numpy/__init__.py"))

        try TerminalAppServer.mergeSitePackages(from: source, to: dest)
        #expect(read(dest.appendingPathComponent("numpy/__init__.py")) == "numpy")
    }

    // MARK: - provisionPythonStdlib

    @Test("stdlib provisioning fully replaces stdlib but merges site-packages")
    func stdlibFullReplaceSitePackagesMerge() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let source = tmp.appendingPathComponent("source-stdlib")
        let dest = tmp.appendingPathComponent("dest-stdlib")

        // Source stdlib: os.py + new numpy bundled.
        try write("import sys", to: source.appendingPathComponent("os.py"))
        try write("import asyncio", to: source.appendingPathComponent("asyncio/__init__.py"))
        try write("numpy 2.4.4", to: source.appendingPathComponent("site-packages/numpy/__init__.py"))

        // Destination: stale os.py + stale_module.py (not in new source) + numpy old + user librosa.
        try write("old import sys", to: dest.appendingPathComponent("os.py"))
        try write("# removed in new version", to: dest.appendingPathComponent("stale_module.py"))
        try write("numpy 2.3.0", to: dest.appendingPathComponent("site-packages/numpy/__init__.py"))
        try write("# user", to: dest.appendingPathComponent("site-packages/librosa/__init__.py"))

        try TerminalAppServer.provisionPythonStdlib(from: source, to: dest)

        // stdlib was fully replaced: os.py from source, stale_module.py gone, asyncio present.
        #expect(read(dest.appendingPathComponent("os.py")) == "import sys")
        #expect(!FileManager.default.fileExists(
            atPath: dest.appendingPathComponent("stale_module.py").path
        ))
        #expect(read(dest.appendingPathComponent("asyncio/__init__.py")) == "import asyncio")

        // site-packages: bundled numpy updated, user librosa preserved.
        #expect(read(dest.appendingPathComponent("site-packages/numpy/__init__.py")) == "numpy 2.4.4")
        #expect(read(dest.appendingPathComponent("site-packages/librosa/__init__.py")) == "# user")
    }

    @Test("stdlib provisioning into empty destination creates the full tree")
    func stdlibProvisionIntoEmpty() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let source = tmp.appendingPathComponent("source")
        let dest = tmp.appendingPathComponent("dest")  // doesn't exist
        try write("import sys", to: source.appendingPathComponent("os.py"))
        try write("numpy 1.0", to: source.appendingPathComponent("site-packages/numpy/__init__.py"))

        try TerminalAppServer.provisionPythonStdlib(from: source, to: dest)

        #expect(read(dest.appendingPathComponent("os.py")) == "import sys")
        #expect(read(dest.appendingPathComponent("site-packages/numpy/__init__.py")) == "numpy 1.0")
    }
}
