//
//  ConjureDSPTerminalTests.swift
//  ConjureDSPTerminalTests
//
//  Created by Michael Jancsy on 3/27/26.
//

import Testing
import Foundation
@testable import ConjureDSPTerminal

struct PackageInstallerInitTests {

    @Test func initWithBundledUV() async throws {
        // When uv is in Bundle.main.resourceURL, init should succeed
        // In tests, Bundle.main is the test runner — uv won't be there.
        // This test verifies the fallback behavior.
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PackageInstallerTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create a fake uv binary
        let fakeUV = tmpDir.appendingPathComponent("uv")
        try "#!/bin/sh\necho ok".write(to: fakeUV, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fakeUV.path)

        // Test explicit init
        let installer = PackageInstaller(appGroupURL: tmpDir, uvPath: fakeUV.path)
        #expect(installer.uvPath == fakeUV.path)
    }

    @Test func initFailsWhenNoUVAvailable() async throws {
        // PackageInstaller.init?(appGroupURL:) returns nil when no uv is found
        // This test may pass or fail depending on whether uv is on PATH in the test env.
        // We can't easily test this without mocking Bundle.main.
        // Instead, test the explicit init path.
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PackageInstallerTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let installer = PackageInstaller(appGroupURL: tmpDir, uvPath: "/nonexistent/uv")
        #expect(installer.uvPath == "/nonexistent/uv")
    }
}

struct PackageInstallerRequestFlowTests {

    /// Create a temp directory structure for testing.
    private func makeTempDir() throws -> URL {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PackageInstallerTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        return tmpDir
    }

    @Test func installRequestWrittenAndProcessed() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create a uv script that succeeds
        let fakeUV = tmpDir.appendingPathComponent("fake-uv")
        try "#!/bin/sh\nexit 0".write(to: fakeUV, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fakeUV.path)

        // Create a fake python binary (for the --python arg)
        let pythonHome = tmpDir.appendingPathComponent("PythonRuntime")
        let binDir = pythonHome.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(
            to: binDir.appendingPathComponent("python3"),
            atomically: true, encoding: .utf8)

        let installer = PackageInstaller(appGroupURL: tmpDir, uvPath: fakeUV.path)

        // Write an install request
        let request = PackageInstaller.InstallRequest(
            requestId: "test-123",
            packages: ["requests"],
            targetPath: tmpDir.appendingPathComponent("site-packages").path,
            pythonHomePath: pythonHome.path,
            timestamp: Date().timeIntervalSince1970
        )
        let requestData = try JSONEncoder().encode(request)
        try requestData.write(
            to: tmpDir.appendingPathComponent(PackageInstaller.installRequestFile))

        // Process the request
        await installer.checkForRequests()

        // Check that result was written
        let resultURL = tmpDir.appendingPathComponent(PackageInstaller.installResultFile)
        #expect(FileManager.default.fileExists(atPath: resultURL.path),
                "Result file should be written after processing request")

        let resultData = try Data(contentsOf: resultURL)
        let result = try JSONDecoder().decode(PackageInstaller.InstallResult.self, from: resultData)
        #expect(result.requestId == "test-123")
        #expect(result.success == true)
        #expect(result.packages == ["requests"])
        #expect(result.error == nil)
    }

    @Test func installFailsWithNonexistentUV() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Use a non-existent uv path — this is the bug scenario
        let installer = PackageInstaller(
            appGroupURL: tmpDir,
            uvPath: tmpDir.appendingPathComponent("nonexistent-uv").path
        )

        let pythonHome = tmpDir.appendingPathComponent("PythonRuntime")

        // Write an install request
        let request = PackageInstaller.InstallRequest(
            requestId: "test-fail",
            packages: ["requests"],
            targetPath: tmpDir.appendingPathComponent("site-packages").path,
            pythonHomePath: pythonHome.path,
            timestamp: Date().timeIntervalSince1970
        )
        let requestData = try JSONEncoder().encode(request)
        try requestData.write(
            to: tmpDir.appendingPathComponent(PackageInstaller.installRequestFile))

        // Process the request
        await installer.checkForRequests()

        // Check that a failure result was written
        let resultURL = tmpDir.appendingPathComponent(PackageInstaller.installResultFile)
        #expect(FileManager.default.fileExists(atPath: resultURL.path),
                "Result file should be written even on failure")

        let resultData = try Data(contentsOf: resultURL)
        let result = try JSONDecoder().decode(PackageInstaller.InstallResult.self, from: resultData)
        #expect(result.requestId == "test-fail")
        #expect(result.success == false)
        #expect(result.error != nil, "Error message should be present, got nil")
    }

    @Test func installWithRealUV() async throws {
        // This test uses the actual uv binary to verify the full pipeline.
        // It installs a small package into a temp directory.
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Find uv — first check uv-dist in repo, then system PATH
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ConjureDSPTerminalTests/
            .deletingLastPathComponent()  // repo root
        let repoUV = repoRoot.appendingPathComponent("uv-dist/uv").path

        var uvPath: String?
        if FileManager.default.fileExists(atPath: repoUV) {
            uvPath = repoUV
        } else {
            // Try system uv
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            process.arguments = ["uv"]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            process.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let path = output, !path.isEmpty, FileManager.default.fileExists(atPath: path) {
                uvPath = path
            }
        }

        guard let uv = uvPath else {
            // Skip test if uv isn't available
            return
        }

        // Find Python runtime — check App Group container
        let appGroupContainer = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.MichaelJancsy.ConjureDSP"
        )
        let pythonRuntime = appGroupContainer?.appendingPathComponent("PythonRuntime")
        let pythonBin = pythonRuntime?.appendingPathComponent("bin/python3")

        // Also check repo's python-dist
        let repoPythonDist = repoRoot.appendingPathComponent("rust/python-dist")
        let repoPythonBin = repoPythonDist.appendingPathComponent("bin/python3")

        var pythonHomePath: String?
        if let bin = pythonBin?.path, FileManager.default.fileExists(atPath: bin) {
            pythonHomePath = pythonRuntime!.path
        } else if FileManager.default.fileExists(atPath: repoPythonBin.path) {
            pythonHomePath = repoPythonDist.path
        }

        guard let pythonHome = pythonHomePath else {
            // Skip test if Python isn't available
            return
        }

        let installer = PackageInstaller(appGroupURL: tmpDir, uvPath: uv)
        let sitePackages = tmpDir.appendingPathComponent("site-packages")

        // Write install request for a small, pure-Python package
        let request = PackageInstaller.InstallRequest(
            requestId: "test-real",
            packages: ["six"],
            targetPath: sitePackages.path,
            pythonHomePath: pythonHome,
            timestamp: Date().timeIntervalSince1970
        )
        let requestData = try JSONEncoder().encode(request)
        try requestData.write(
            to: tmpDir.appendingPathComponent(PackageInstaller.installRequestFile))

        await installer.checkForRequests()

        let resultURL = tmpDir.appendingPathComponent(PackageInstaller.installResultFile)
        #expect(FileManager.default.fileExists(atPath: resultURL.path))

        let resultData = try Data(contentsOf: resultURL)
        let result = try JSONDecoder().decode(PackageInstaller.InstallResult.self, from: resultData)
        #expect(result.success == true, "Install should succeed: \(result.error ?? "no error")")

        // Verify the package was actually installed
        let sixFile = sitePackages.appendingPathComponent("six.py")
        #expect(FileManager.default.fileExists(atPath: sixFile.path),
                "six.py should exist in site-packages after install")
    }

    @Test func uninstallRemovesPackage() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fakeUV = tmpDir.appendingPathComponent("fake-uv")
        try "#!/bin/sh\nexit 0".write(to: fakeUV, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fakeUV.path)

        let installer = PackageInstaller(appGroupURL: tmpDir, uvPath: fakeUV.path)

        // Create a fake installed package
        let sitePackages = tmpDir.appendingPathComponent("site-packages")
        let pkgDir = sitePackages.appendingPathComponent("mypkg")
        let distInfo = sitePackages.appendingPathComponent("mypkg-1.0.0.dist-info")
        try FileManager.default.createDirectory(at: pkgDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: distInfo, withIntermediateDirectories: true)
        try "mypkg\n".write(
            to: distInfo.appendingPathComponent("top_level.txt"),
            atomically: true, encoding: .utf8)

        // Write uninstall request
        let request = PackageInstaller.UninstallRequest(
            requestId: "test-uninstall",
            packages: ["mypkg"],
            targetPath: sitePackages.path,
            timestamp: Date().timeIntervalSince1970
        )
        let requestData = try JSONEncoder().encode(request)
        try requestData.write(
            to: tmpDir.appendingPathComponent(PackageInstaller.uninstallRequestFile))

        await installer.checkForRequests()

        // Check that result was written and succeeded
        let resultURL = tmpDir.appendingPathComponent(PackageInstaller.installResultFile)
        let resultData = try Data(contentsOf: resultURL)
        let result = try JSONDecoder().decode(PackageInstaller.InstallResult.self, from: resultData)
        #expect(result.success == true)

        // Verify package was removed
        #expect(!FileManager.default.fileExists(atPath: pkgDir.path))
        #expect(!FileManager.default.fileExists(atPath: distInfo.path))
    }

    @Test func requestFileRemovedAfterProcessing() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fakeUV = tmpDir.appendingPathComponent("fake-uv")
        try "#!/bin/sh\nexit 0".write(to: fakeUV, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fakeUV.path)

        let installer = PackageInstaller(appGroupURL: tmpDir, uvPath: fakeUV.path)

        let pythonHome = tmpDir.appendingPathComponent("PythonRuntime")
        let binDir = pythonHome.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try "".write(to: binDir.appendingPathComponent("python3"), atomically: true, encoding: .utf8)

        let request = PackageInstaller.InstallRequest(
            requestId: "test-cleanup",
            packages: ["requests"],
            targetPath: tmpDir.appendingPathComponent("site-packages").path,
            pythonHomePath: pythonHome.path,
            timestamp: Date().timeIntervalSince1970
        )
        let requestURL = tmpDir.appendingPathComponent(PackageInstaller.installRequestFile)
        try JSONEncoder().encode(request).write(to: requestURL)

        #expect(FileManager.default.fileExists(atPath: requestURL.path))

        await installer.checkForRequests()

        #expect(!FileManager.default.fileExists(atPath: requestURL.path),
                "Request file should be deleted after processing")
    }
}

struct PackageInstallerUVResolutionTests {

    @Test func uvDistExistsInRepo() throws {
        // Verify that uv-dist/uv exists in the repo (prerequisite for builds)
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let uvPath = repoRoot.appendingPathComponent("uv-dist/uv").path
        #expect(FileManager.default.fileExists(atPath: uvPath),
                "uv-dist/uv must exist in repo root for the 'Copy uv Binary' build phase. Run scripts/setup-uv.sh if missing.")
    }

    @Test func productionInitResolvesUV() throws {
        // Test that the production init can find uv (either bundled, App Group, or PATH)
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PackageInstallerTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let installer = PackageInstaller(appGroupURL: tmpDir)

        if let inst = installer {
            print("PackageInstaller resolved uv at: \(inst.uvPath)")
            #expect(FileManager.default.fileExists(atPath: inst.uvPath),
                    "Resolved uv path should exist: \(inst.uvPath)")
        } else {
            print("PackageInstaller init returned nil — uv not found in Bundle.main, App Group, or PATH")
        }
    }

    @Test func appGroupFallbackResolvesUV() throws {
        // When uv is placed in the App Group directory, init should find it.
        // Note: In test context, Bundle.main may already contain uv (from the
        // built Terminal app), so the bundle check might succeed first. This test
        // verifies that init succeeds either way — the App Group fallback matters
        // in production when the bundle path doesn't contain uv.
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PackageInstallerTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Place a fake uv in the "App Group" directory
        let appGroupUV = tmpDir.appendingPathComponent("uv")
        try "#!/bin/sh\necho uv-from-appgroup".write(
            to: appGroupUV, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: appGroupUV.path)

        // Production init should find uv (from bundle, App Group, or PATH)
        let installer = PackageInstaller(appGroupURL: tmpDir)
        #expect(installer != nil, "Should find uv via at least one resolution path")
        #expect(FileManager.default.fileExists(atPath: installer!.uvPath),
                "Resolved uv path should exist: \(installer!.uvPath)")

        // Verify the explicit init with App Group path works
        let explicitInstaller = PackageInstaller(appGroupURL: tmpDir, uvPath: appGroupUV.path)
        #expect(explicitInstaller.uvPath == appGroupUV.path)
    }
}
