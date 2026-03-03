// RustCompilerTests.swift
// Tests for Rust compiler discovery logic.
// Self-contained (no extension imports) to avoid duplicate symbol issues.

import Foundation
import Testing

@Suite("Rust Compiler Discovery")
struct RustCompilerDiscoveryTests {

    /// The real user home directory via getpwuid (bypasses sandbox container redirection).
    private var realUserHome: String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }

    // MARK: - Home Directory Resolution

    @Test func getpwuidReturnsRealHome() {
        let home = realUserHome
        // Should be a real user directory, not a container path
        #expect(home.hasPrefix("/Users/") || home.hasPrefix("/var/"),
                "getpwuid home should be a real user directory, got: \(home)")
        #expect(!home.contains("Library/Containers"),
                "getpwuid home should not be a container path, got: \(home)")
    }

    @Test func nsHomeDirectoryMayDifferFromGetpwuid() {
        // NSHomeDirectory() often returns a container path in AU/test host contexts.
        // This test documents the behavior — it's the reason we use getpwuid instead.
        let nsHome = NSHomeDirectory()
        let pwHome = realUserHome
        if nsHome != pwHome {
            // Expected in sandboxed/container contexts — document it
            #expect(nsHome.contains("Library/Containers") || nsHome.contains("Library/Group"),
                    "If NSHomeDirectory differs, it should be a container path, got: \(nsHome)")
        }
        // Either way, getpwuid should give a real home
        #expect(!pwHome.contains("Library/Containers"))
    }

    // MARK: - Rustc Discovery

    @Test func rustcExistsAtCargoPath() throws {
        let home = realUserHome
        let rustcPath = "\(home)/.cargo/bin/rustc"

        // Skip if rustc is not installed (CI environments, etc.)
        try #require(FileManager.default.fileExists(atPath: rustcPath),
                     "rustc not installed at \(rustcPath) — skip test")

        // rustc is typically a symlink to rustup
        let isSymlink = (try? FileManager.default.destinationOfSymbolicLink(atPath: rustcPath)) != nil
        if isSymlink {
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: rustcPath)
            #expect(target == "rustup",
                    "rustc symlink should point to rustup, got: \(target)")
        }
    }

    @Test func posixAccessFindsRustcSymlink() throws {
        let home = realUserHome
        let rustcPath = "\(home)/.cargo/bin/rustc"
        try #require(FileManager.default.fileExists(atPath: rustcPath),
                     "rustc not installed — skip test")

        // POSIX access() follows symlinks and checks real executability.
        let result = access(rustcPath, X_OK)
        #expect(result == 0,
                "access(\(rustcPath), X_OK) should succeed (got errno: \(errno))")
    }

    @Test func fileManagerIsExecutableOnResolvedSymlink() throws {
        let home = realUserHome
        let rustcPath = "\(home)/.cargo/bin/rustc"
        try #require(FileManager.default.fileExists(atPath: rustcPath),
                     "rustc not installed — skip test")

        // Resolving symlinks first, then checking, should also work
        let resolved = URL(fileURLWithPath: rustcPath).resolvingSymlinksInPath().path
        let executable = FileManager.default.isExecutableFile(atPath: resolved)
        #expect(executable,
                "isExecutableFile on resolved path (\(resolved)) should succeed")
    }

    @Test func fileManagerIsExecutableOnSymlinkDirectly() throws {
        let home = realUserHome
        let rustcPath = "\(home)/.cargo/bin/rustc"
        try #require(FileManager.default.fileExists(atPath: rustcPath),
                     "rustc not installed — skip test")

        // Document whether isExecutableFile works directly on the symlink.
        // This may fail in some contexts due to com.apple.provenance xattr.
        let executable = FileManager.default.isExecutableFile(atPath: rustcPath)
        if !executable {
            let isSymlink = (try? FileManager.default.destinationOfSymbolicLink(atPath: rustcPath)) != nil
            Issue.record("""
                FileManager.isExecutableFile returned false for \(rustcPath) \
                (isSymlink: \(isSymlink)). Use access(path, X_OK) instead.
                """)
        }
    }

    // MARK: - Candidate Path Search (mirrors RustCompiler.findRustc logic)

    @Test func candidateSearchFindsRustcViaFileExists() throws {
        let home = realUserHome
        let candidates = [
            "\(home)/.cargo/bin/rustc",
            "/usr/local/bin/rustc",
            "/opt/homebrew/bin/rustc",
        ]

        // RustCompiler.findRustc() uses fileExists (not access/isExecutable)
        // because AU extension sandbox returns EPERM for permission checks.
        var found: String?
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                found = path
                break
            }
        }

        try #require(found != nil,
                     "Should find rustc in one of the candidate paths. Checked: \(candidates)")
        #expect(found!.contains(".cargo/bin/rustc"),
                "Expected to find rustc at ~/.cargo/bin/rustc, but found at: \(found!)")
    }

    // MARK: - Sandbox Detection (mirrors RustCompiler.isSandboxRestricted)

    @Test func sandboxDetectionHeuristic() {
        // RustCompiler uses NSHomeDirectory() container path as a sandbox signal.
        // In the test host this may or may not indicate a container.
        let nsHome = NSHomeDirectory()
        let isSandboxed = nsHome.contains("Library/Containers") || nsHome.contains("Library/Group")

        if isSandboxed {
            // We're in a container — the heuristic correctly detects sandbox
            #expect(nsHome != realUserHome,
                    "In a container, NSHomeDirectory should differ from getpwuid home")
        }
        // Either way, getpwuid should give a real path
        #expect(!realUserHome.contains("Library/Containers"))
    }

    // Note: Process execution (running rustc --print target-list) is restricted
    // in the test host due to sandboxing. WASM target availability is tested
    // via the UI test (testRustPresetCompilesSuccessfully) instead.
}
