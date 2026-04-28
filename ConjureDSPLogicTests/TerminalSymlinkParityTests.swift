//
//  TerminalSymlinkParityTests.swift
//  ConjureDSPLogicTests
//
//  Three Terminal source files (AgentCatalog.swift, WebSocketServer.swift,
//  LaunchQueue.swift) are needed by both the ConjureDSPTerminal companion
//  app and ConjureDSPLogicTests, but the Terminal target can't be linked
//  into the test target. Rather than ship duplicate copies — which already
//  drifted once during the custom-ui→main merge (the LogicTests copy of
//  WebSocketServer.swift was 10 lines stale, missing the retain-pending
//  fix) — the LogicTests paths are SYMLINKS pointing at the Terminal
//  sources. Xcode's PBXFileSystemSynchronizedRootGroup follows symlinks
//  at compile time, so the LogicTests target compiles the same source
//  the companion app does.
//
//  This test fails if someone replaces a symlink with a regular file
//  (intentionally or by accident — `cp` instead of `ln -s`, an editor
//  that materializes symlinks on save, etc.). With the symlinks in
//  place the tests trivially pass.
//
//  AppGroupContainer.swift is intentionally NOT in the symlinked set —
//  the LogicTests copy is a deliberate stub for the unsandboxed test
//  environment (uses Application Support instead of the App Group
//  container). Don't add it here without converting the stub into a
//  build-time switch first.
//

import Foundation
import Testing

@Suite("Terminal/LogicTests symlink parity")
struct TerminalSymlinkParityTests {

    /// Repo root, derived from this test file's path.
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ConjureDSPLogicTests/
            .deletingLastPathComponent()   // repo root
    }

    /// Asserts that `ConjureDSPLogicTests/<filename>` is a symbolic link
    /// pointing at `../ConjureDSPTerminal/<filename>`.
    private static func expectSymlink(filename: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let path = Self.repoRoot
            .appendingPathComponent("ConjureDSPLogicTests")
            .appendingPathComponent(filename)
            .path

        // 1. Path exists AND is a symbolic link.
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let fileType = attrs[.type] as? FileAttributeType
        #expect(fileType == .typeSymbolicLink, """
            ConjureDSPLogicTests/\(filename) is not a symbolic link (type=\(fileType?.rawValue ?? "nil")).

            It must be a symlink to ../ConjureDSPTerminal/\(filename) so the
            LogicTests target compiles the same source the Terminal companion
            app does. If someone replaced the symlink with a regular file,
            restore it with:

                rm "ConjureDSPLogicTests/\(filename)"
                ln -s "../ConjureDSPTerminal/\(filename)" "ConjureDSPLogicTests/\(filename)"
            """,
            sourceLocation: sourceLocation
        )

        // 2. Target path is exactly the expected relative path.
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: path)
        let expected = "../ConjureDSPTerminal/\(filename)"
        #expect(target == expected, """
            ConjureDSPLogicTests/\(filename) points at the wrong target:
              actual:   \(target)
              expected: \(expected)
            """,
            sourceLocation: sourceLocation
        )
    }

    @Test func agentCatalogIsSymlinkedToTerminalSource() throws {
        try Self.expectSymlink(filename: "AgentCatalog.swift")
    }

    @Test func webSocketServerIsSymlinkedToTerminalSource() throws {
        try Self.expectSymlink(filename: "WebSocketServer.swift")
    }

    @Test func launchQueueIsSymlinkedToTerminalSource() throws {
        try Self.expectSymlink(filename: "LaunchQueue.swift")
    }
}
