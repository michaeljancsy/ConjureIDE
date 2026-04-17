//
//  LanguageModuleManagerIPCTests.swift
//  ConjureDSPLogicTests
//
//  Covers the file-cleanup side of LanguageModuleManager that's safe to
//  exercise from a logic-tests target (no @MainActor observable class needed).
//  This is the core of cancelCurrentOperation + downloader-restart recovery:
//  every stale install/uninstall request and result file under the App Group
//  container root must be removable on demand.
//

import Foundation
import Testing

@Suite("LanguageModuleManager IPC file cleanup")
struct LanguageModuleManagerIPCTests {

    private func makeTempContainer() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LMM-IPC-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try text.data(using: .utf8)!.write(to: url)
    }

    @Test("clearPendingIPCFiles removes all three IPC files")
    func clearRemovesAll() throws {
        let container = try makeTempContainer()
        defer { try? FileManager.default.removeItem(at: container) }

        let install = container.appendingPathComponent(LanguageModuleIPC.installRequestFile)
        let uninstall = container.appendingPathComponent(LanguageModuleIPC.uninstallRequestFile)
        let result = container.appendingPathComponent(LanguageModuleIPC.installResultFile)
        try write("{}", to: install)
        try write("{}", to: uninstall)
        try write("{}", to: result)

        LanguageModuleManager.clearPendingIPCFiles(in: container)

        #expect(!FileManager.default.fileExists(atPath: install.path))
        #expect(!FileManager.default.fileExists(atPath: uninstall.path))
        #expect(!FileManager.default.fileExists(atPath: result.path))
    }

    @Test("clearPendingIPCFiles is safe when nothing is there (no throw)")
    func clearOnEmptyContainerIsSafe() throws {
        let container = try makeTempContainer()
        defer { try? FileManager.default.removeItem(at: container) }

        LanguageModuleManager.clearPendingIPCFiles(in: container)
        // Just assert we got here.
        #expect(FileManager.default.fileExists(atPath: container.path))
    }

    @Test("clearPendingIPCFiles leaves unrelated files alone")
    func clearLeavesOtherFilesAlone() throws {
        let container = try makeTempContainer()
        defer { try? FileManager.default.removeItem(at: container) }

        let install = container.appendingPathComponent(LanguageModuleIPC.installRequestFile)
        let untouched = container.appendingPathComponent("user-data.json")
        let modules = container.appendingPathComponent(LanguageModuleIPC.modulesDirectory)
        try write("{}", to: install)
        try write("{\"presets\":[]}", to: untouched)
        try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)

        LanguageModuleManager.clearPendingIPCFiles(in: container)

        #expect(!FileManager.default.fileExists(atPath: install.path))
        #expect(FileManager.default.fileExists(atPath: untouched.path))
        #expect(FileManager.default.fileExists(atPath: modules.path))
    }

    // MARK: - containerURLOverride

    @Test("containerURLOverride redirects containerURL() + isInstalled()")
    func containerOverrideTakesEffect() throws {
        let container = try makeTempContainer()
        defer {
            LanguageModuleManager.containerURLOverride = nil
            try? FileManager.default.removeItem(at: container)
        }

        LanguageModuleManager.containerURLOverride = container
        #expect(LanguageModuleManager.containerURL() == container)

        // isInstalled uses moduleDirectory → containerURL, so it should
        // probe inside the override.
        let pythonDir = container
            .appendingPathComponent(LanguageModuleIPC.modulesDirectory)
            .appendingPathComponent("python")
        try FileManager.default.createDirectory(at: pythonDir, withIntermediateDirectories: true)
        #expect(LanguageModuleManager.isInstalled("python") == false)

        try write("{}", to: pythonDir.appendingPathComponent(LanguageModuleIPC.manifestFile))
        #expect(LanguageModuleManager.isInstalled("python") == true)
    }

    @Test("moduleDirectory builds <container>/LanguageModules/<name>")
    func moduleDirectoryPath() throws {
        let container = try makeTempContainer()
        defer {
            LanguageModuleManager.containerURLOverride = nil
            try? FileManager.default.removeItem(at: container)
        }
        LanguageModuleManager.containerURLOverride = container

        let python = LanguageModuleManager.moduleDirectory(for: "python")
        #expect(
            python.path == container
                .appendingPathComponent(LanguageModuleIPC.modulesDirectory)
                .appendingPathComponent("python")
                .path
        )
    }
}
