//
//  CustomUIAssetParityTests.swift
//  ConjureDSPLogicTests
//
//  The main extension and the export template each ship their own
//  copy of `cdp-ui.js` and `customui-bridge.js` in their Resources.
//  These files MUST stay byte-identical: the main plugin's custom UI
//  webview and the exported AU's custom UI webview run the same
//  preset HTML, and any divergence means a preset that works
//  in-plugin will silently misbehave (or fail to render) once
//  exported.
//
//  Concrete past failure: cdp-ui.js diverged at commit 01b7b72 (the
//  initial component-library import). Five subsequent fixes landed
//  on the main extension's copy — including
//    85bb1e3  Fix cdp-xy puck / cdp-choice selection not updating
//    1150505  Fix custom-element upgrade bug
//  — without being mirrored into the export template's copy. Result:
//  exported AUs of presets that use <cdp-xy> rendered with no
//  visible interactive surface. The export template's bridge JS had
//  the same problem in parallel.
//
//  Sync mechanism: the export template's Resources/cdp-ui.js and
//  Resources/customui-bridge.js are SYMLINKS pointing at the main
//  extension's Resources. Xcode's Copy Bundle Resources phase
//  follows the symlinks at build time and bundles the resolved
//  file content — so an exported `.appex` always contains exactly
//  the same JS the main extension ships. Drift becomes structurally
//  impossible: there's only one source of truth on disk.
//
//  This test is the belt-and-suspenders regression guard. It fails
//  if someone deletes a symlink and replaces it with a stale
//  duplicate, or if main is updated but the symlink got reverted
//  to a real file at some point. With the symlinks in place both
//  paths resolve to the same content and the test trivially passes.
//

import CryptoKit
import Foundation
import Testing

@Suite("Custom UI asset parity")
struct CustomUIAssetParityTests {

    /// Repo root, derived from this test file's path.
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ConjureDSPLogicTests/
            .deletingLastPathComponent()   // repo root
    }

    private static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// `cdp-ui.js` defines every cdp-* web component. If the export
    /// template's copy lags behind the main extension, exported AUs
    /// render preset UIs against a stale component library — the
    /// concrete failure mode that produced the missing-cdp-xy bug.
    @Test func cdpUIIsByteIdenticalAcrossMainAndExportTemplate() throws {
        let main = Self.repoRoot
            .appendingPathComponent("ConjureDSPExtension/Resources/cdp-ui.js")
        let template = Self.repoRoot
            .appendingPathComponent("ConjureDSPExportAUTemplate/ConjureDSPExportAUTemplateExtension/Resources/cdp-ui.js")

        let mainHash = try Self.sha256(of: main)
        let tplHash = try Self.sha256(of: template)

        #expect(mainHash == tplHash, """
            cdp-ui.js drift between main extension and export template:
              main:     \(mainHash)
              template: \(tplHash)
            Re-sync the export template's copy with the main extension's, OR
            wire up a build script / symlink so the template's copy is always
            generated from the main extension's. Otherwise exported AUs render
            against a stale component library and presets that use updated
            components (cdp-xy, cdp-choice, etc.) silently misbehave.
            """)
    }

    /// `customui-bridge.js` is the JS bridge between the webview and
    /// the AU's parameter tree (window.ConjureDSP.parameters,
    /// onChange, etc). Same parity contract — drift here means an
    /// exported preset's bindings can fall out of sync with what the
    /// in-plugin preview shows.
    @Test func customUIBridgeIsByteIdenticalAcrossMainAndExportTemplate() throws {
        let main = Self.repoRoot
            .appendingPathComponent("ConjureDSPExtension/Resources/customui-bridge.js")
        let template = Self.repoRoot
            .appendingPathComponent("ConjureDSPExportAUTemplate/ConjureDSPExportAUTemplateExtension/Resources/customui-bridge.js")

        let mainHash = try Self.sha256(of: main)
        let tplHash = try Self.sha256(of: template)

        #expect(mainHash == tplHash, """
            customui-bridge.js drift between main extension and export template:
              main:     \(mainHash)
              template: \(tplHash)
            Re-sync. The bridge is what backs window.ConjureDSP — drift means
            exported AUs run a different version of the parameter API than the
            in-plugin preview, so preset HTML that works in-plugin can break
            once exported.
            """)
    }
}
