//
//  ExportTemplateFreshnessTests.swift
//  ConjureDSPLogicTests
//
//  Catches the "stale export template" bug where xcodebuild's incremental
//  build produces a SUCCESS that didn't actually recompile changed template
//  Swift files, so the ExportTemplate.zip bundled into ConjureDSP.app ships
//  yesterday's code. Exports made with that stale zip all carry old UI.
//
//  We've hit this once in production-style dev flow: after editing
//  ExportAUMainView.swift (changing the debug pane to full-window), the
//  template's `build/` incremental state didn't track the edit, the rebuild
//  script re-zipped the stale .app unchanged, and the exported AU shipped
//  without the fix. "Looks fine locally, broken in the exported copy" is
//  exactly the kind of bug an automated check should prevent.
//
//  The check is coarse but robust: every .swift / .plist / .entitlements file
//  under ConjureDSPExportAUTemplateExtension/ must have an mtime older than
//  the compiled extension binary inside the bundled ExportTemplate.zip. If
//  that invariant holds, the zip contains a build that ran AFTER the sources
//  were last touched.
//

import Foundation
import Testing

struct ExportTemplateFreshnessTests {
    /// Source tree root resolved from the test file's compile-time path.
    /// `#filePath` bakes in the absolute path of this file at build time;
    /// walking up two directories gets us to the project root.
    private static func projectRoot() -> URL {
        let thisFile = URL(fileURLWithPath: #filePath)
        return thisFile
            .deletingLastPathComponent()  // ConjureDSPLogicTests/
            .deletingLastPathComponent()  // project root
    }

    /// The ExportTemplate.zip bundled in the just-built ConjureDSP.app.
    /// Logic tests don't host the app, so `Bundle.main` is the xctest runner,
    /// not ConjureDSP.app. We look relative to the test bundle's own location
    /// (which IS in the same BUILT_PRODUCTS_DIR as the host app when built
    /// via `xcodebuild test`) to find the fresh zip.
    private static func findBundledTemplate() -> URL? {
        // Test bundle lives at: <BUILT_PRODUCTS_DIR>/ConjureDSPLogicTests.xctest
        // Host app lives at: <BUILT_PRODUCTS_DIR>/ConjureDSP.app
        // So walk up once and look for ConjureDSP.app/Contents/PlugIns/...
        let testBundle = Bundle(for: BundleLocator.self)
        let buildProductsDir = testBundle.bundleURL.deletingLastPathComponent()
        let zipURL = buildProductsDir
            .appendingPathComponent("ConjureDSP.app")
            .appendingPathComponent("Contents/PlugIns/ConjureDSPExtension.appex")
            .appendingPathComponent("Contents/Resources/ExportTemplate.zip")
        if FileManager.default.fileExists(atPath: zipURL.path) {
            return zipURL
        }
        return nil
    }

    /// Empty class used solely to give `Bundle(for:)` a type anchored in this
    /// test bundle (Swift Testing structs can't be passed to `Bundle(for:)`).
    private final class BundleLocator {}

    /// Recursively finds every source file under the template's extension
    /// directory that the Swift/Objective-C compiler would care about.
    private static func templateSourceFiles() -> [URL] {
        let root = projectRoot()
            .appendingPathComponent("ConjureDSPExportAUTemplate")
            .appendingPathComponent("ConjureDSPExportAUTemplateExtension")
        let extensions: Set<String> = ["swift", "m", "mm", "c", "cpp", "h", "plist", "entitlements"]
        var result: [URL] = []
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        for case let url as URL in enumerator {
            if extensions.contains(url.pathExtension) {
                result.append(url)
            }
        }
        return result
    }

    private static func mtime(of url: URL) -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attrs?[.modificationDate] as? Date
    }

    /// The freshness invariant: the extension binary inside ExportTemplate.zip
    /// must be newer than every template source file. If this ever fails,
    /// every exported AU built from this host app is shipping stale code.
    @Test func bundledTemplateBinaryIsNewerThanSources() throws {
        guard let templateURL = Self.findBundledTemplate() else {
            // Not running from a built host app (e.g. logic-tests-only via
            // a different scheme) — skip rather than fail.
            print("Skipping: ExportTemplate.zip not reachable from Bundle.main")
            return
        }

        let sources = Self.templateSourceFiles()
        try #require(!sources.isEmpty, "Expected to find template source files — source tree layout changed?")

        // Unzip just enough to stat the extension binary.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cdp-template-freshness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", templateURL.path, "-d", tmp.path]
        try unzip.run()
        unzip.waitUntilExit()
        try #require(unzip.terminationStatus == 0, "unzip of ExportTemplate.zip failed")

        let binary = tmp
            .appendingPathComponent("ConjureDSPExportAUTemplate.app")
            .appendingPathComponent("Contents/PlugIns/ConjureDSPExportAUTemplateExtension.appex")
            .appendingPathComponent("Contents/MacOS/ConjureDSPExportAUTemplateExtension")
        try #require(FileManager.default.fileExists(atPath: binary.path),
                    "Extension binary missing from unzipped template")

        guard let binaryMtime = Self.mtime(of: binary) else {
            Issue.record("Could not stat extension binary")
            return
        }

        // Find the newest source file.
        var newestSource: URL?
        var newestMtime: Date = .distantPast
        for source in sources {
            guard let m = Self.mtime(of: source) else { continue }
            if m > newestMtime {
                newestMtime = m
                newestSource = source
            }
        }

        // Allow a small tolerance: filesystem timestamps can round to the
        // second, and some build steps touch output files slightly later
        // than the source mtime snapshot. 5 seconds is generous; anything
        // larger indicates a real "stale template" bug.
        let tolerance: TimeInterval = 5
        let effectiveSourceMtime = newestMtime.addingTimeInterval(-tolerance)

        if binaryMtime < effectiveSourceMtime, let newest = newestSource {
            Issue.record("""
                Export template is STALE. The ExportTemplate.zip bundled in ConjureDSP.app
                contains a binary older than at least one source file. Every AU exported
                from this build will ship yesterday's UI.

                  bundled binary mtime: \(binaryMtime)
                  newest source file:   \(newest.path)
                  newest source mtime:  \(newestMtime)

                Fix: rm -rf ConjureDSPExportAUTemplate/build/Build and rebuild
                ConjureDSP. Or run scripts/rebuild-and-copy-export-template.sh
                which now force-cleans when sources are newer than the binary.
                """)
        }
    }
}
