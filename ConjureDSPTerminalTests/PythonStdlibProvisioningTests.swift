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

    // MARK: - copyPythonBinaries (symlink-chain survival)

    /// Builds a realistic `python-dist/bin/` layout:
    ///   python         -> python3
    ///   python3        -> python3.14
    ///   python3.14     -> python3.14t
    ///   python3.14t    (real file)
    private func makeSymlinkChainBin(at parent: URL) throws -> URL {
        let bin = parent.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        // Real binary file
        try "fake-python-binary".data(using: .utf8)!
            .write(to: bin.appendingPathComponent("python3.14t"))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: bin.appendingPathComponent("python3.14t").path
        )
        // Relative symlinks (what python-build-standalone ships). Use the
        // path-based API — createSymbolicLink(at:withDestinationURL:) would
        // resolve the URL against CWD and write an absolute target, which
        // defeats the purpose since we're testing relative-link survival
        // through copyItem.
        let fm = FileManager.default
        try fm.createSymbolicLink(
            atPath: bin.appendingPathComponent("python3.14").path,
            withDestinationPath: "python3.14t"
        )
        try fm.createSymbolicLink(
            atPath: bin.appendingPathComponent("python3").path,
            withDestinationPath: "python3.14"
        )
        try fm.createSymbolicLink(
            atPath: bin.appendingPathComponent("python").path,
            withDestinationPath: "python3"
        )
        return bin
    }

    @Test("copyPythonBinaries preserves the full python3→3.14→3.14t symlink chain")
    func binSymlinkChainSurvives() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let source = tmp.appendingPathComponent("source")
        let destination = tmp.appendingPathComponent("dest")
        _ = try makeSymlinkChainBin(at: source)

        try TerminalAppServer.copyPythonBinaries(from: source, to: destination)

        // Every chain link exists in dest.
        let dstBin = destination.appendingPathComponent("bin")
        for name in ["python3.14t", "python3.14", "python3", "python"] {
            #expect(
                FileManager.default.fileExists(atPath: dstBin.appendingPathComponent(name).path),
                "missing \(name) in dst bin/"
            )
        }

        // The chain is non-dangling: walk each symlink manually and verify
        // the tail is a real regular file. This is the actual bug the fix
        // prevents. FileManager.fileExists follows symlinks only if every
        // link in the chain resolves; one broken hop returns false.
        let fm = FileManager.default
        let leaf = dstBin.appendingPathComponent("python3")
        #expect(
            fm.fileExists(atPath: leaf.path),
            "python3 symlink chain dangles in dst — fileExists returned false"
        )
        // Symlinks point at relative targets (one level deep each).
        let target1 = try #require(try? fm.destinationOfSymbolicLink(atPath: leaf.path))
        #expect(target1 == "python3.14")
        let next = dstBin.appendingPathComponent(target1)
        let target2 = try #require(try? fm.destinationOfSymbolicLink(atPath: next.path))
        #expect(target2 == "python3.14t")
        let real = dstBin.appendingPathComponent(target2)
        let attrs = try fm.attributesOfItem(atPath: real.path)
        #expect(attrs[.type] as? FileAttributeType == .typeRegular)
    }

    @Test("copyPythonBinaries removes pre-existing dst bin before copy")
    func binCopyIsDestructiveAtDestination() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let source = tmp.appendingPathComponent("source")
        let destination = tmp.appendingPathComponent("dest")
        _ = try makeSymlinkChainBin(at: source)

        // Stale destination with an old extra file that shouldn't linger.
        let dstBin = destination.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: dstBin, withIntermediateDirectories: true)
        try "stale".data(using: .utf8)!
            .write(to: dstBin.appendingPathComponent("old-tool"))

        try TerminalAppServer.copyPythonBinaries(from: source, to: destination)

        #expect(!FileManager.default.fileExists(atPath: dstBin.appendingPathComponent("old-tool").path))
        #expect(FileManager.default.fileExists(atPath: dstBin.appendingPathComponent("python3.14t").path))
    }

    @Test("copyPythonBinaries into a non-existent destination creates the parent")
    func binCopyCreatesDestination() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let source = tmp.appendingPathComponent("source")
        let destination = tmp.appendingPathComponent("nonexistent")  // doesn't exist
        _ = try makeSymlinkChainBin(at: source)

        try TerminalAppServer.copyPythonBinaries(from: source, to: destination)
        #expect(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("bin/python3.14t").path
        ))
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
