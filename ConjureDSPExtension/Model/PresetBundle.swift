import Foundation
import os.log

private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP", category: "PresetBundle")

/// Parsed, validated view of a preset bundle directory on disk.
///
/// Layout:
/// ```
/// <name>.cdp/
///   manifest.json
///   process.py | process.rs
///   ui/
///     index.html
///     assets/
/// ```
///
/// Construction loads and validates `manifest.json`. A bundle is considered to
/// "have a custom UI" only when the manifest declares a `ui` section AND the
/// referenced HTML file actually exists on disk.
struct PresetBundle: Equatable {
    /// The bundle directory on disk.
    let rootURL: URL

    /// Parsed manifest.
    let manifest: PresetManifest

    /// Absolute URL to the DSP entry script (`process.py` / `process.rs`).
    let entryScriptURL: URL

    /// Absolute URL to the HTML entry, if the manifest advertises a UI and the
    /// file exists on disk. Nil when no custom UI is present.
    let uiIndexURL: URL?

    /// Absolute URL to the `ui/` directory when it exists.
    let uiDirectoryURL: URL?

    /// True iff the bundle has a manifest `ui` block AND the HTML entry exists.
    var hasCustomUI: Bool { uiIndexURL != nil }

    /// Display name: the bundle directory's last path component with the
    /// `.cdp` suffix stripped, if present.
    var name: String {
        let last = rootURL.lastPathComponent
        if last.hasSuffix(".\(Self.bundleExtension)") {
            return String(last.dropLast(Self.bundleExtension.count + 1))
        }
        return last
    }

    // MARK: - Constants

    /// Directory-name suffix that identifies a preset bundle. Not strictly
    /// required — a directory containing `manifest.json` is treated as a
    /// bundle regardless of its name — but bundles created by ConjureDSP use
    /// this suffix so they read as a single document in Finder.
    static let bundleExtension = "cdp"

    // MARK: - Loading

    /// Outcome of attempting to parse a directory as a preset bundle.
    ///
    /// Distinguishes "the directory isn't a bundle at all" (no manifest,
    /// or not a directory — a `notABundle` is treated as silent skip)
    /// from "the directory looks like a bundle but failed to parse"
    /// (bad manifest JSON, missing entry script, etc.). The browser /
    /// MCP surfaces broken bundles to the user instead of letting them
    /// silently disappear.
    enum LoadResult: Equatable {
        case ok(PresetBundle)
        /// Bundle directory is present (manifest.json exists) but the
        /// bundle is unloadable. `name` is the directory's
        /// `lastPathComponent` with any `.cdp` suffix stripped, suitable
        /// for showing in a list.
        case broken(name: String, rootURL: URL, error: String)
        /// Path doesn't look like a bundle at all (not a directory, or
        /// no `manifest.json` at the root). The caller should ignore
        /// it — this is the "scan stranger files" case.
        case notABundle
    }

    /// Attempt to load a bundle from a directory. Returns a tagged result so
    /// callers can distinguish "not a bundle" (silent skip) from "broken
    /// bundle" (surface to the user with the parse error).
    ///
    /// Logs at `.error` when transitioning to `.broken` so the failure is
    /// also visible in Console.app even if the UI didn't render it.
    static func loadResult(from rootURL: URL) -> LoadResult {
        let fileManager = FileManager.default
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDir), isDir.boolValue else {
            return .notABundle
        }

        let manifestURL = rootURL.appendingPathComponent(PresetManifest.filename)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return .notABundle
        }

        let bundleName = displayName(for: rootURL)

        let manifest: PresetManifest
        do {
            let data = try Data(contentsOf: manifestURL)
            manifest = try PresetManifest.decode(from: data)
        } catch {
            let message = "Failed to decode manifest at \(manifestURL.path): \(error.localizedDescription)"
            log.error("\(message, privacy: .public)")
            return .broken(name: bundleName, rootURL: rootURL, error: message)
        }

        let entryScriptURL = rootURL.appendingPathComponent(manifest.entry)
        guard fileManager.fileExists(atPath: entryScriptURL.path) else {
            let message = "Entry script missing at \(entryScriptURL.path)"
            log.error("\(message, privacy: .public)")
            return .broken(name: bundleName, rootURL: rootURL, error: message)
        }

        let uiDirURL = rootURL.appendingPathComponent("ui", isDirectory: true)
        let uiDirExists: Bool = {
            var isD: ObjCBool = false
            return fileManager.fileExists(atPath: uiDirURL.path, isDirectory: &isD) && isD.boolValue
        }()

        // Resolve HTML entry only when the manifest actually declares a UI
        // block. A bundle that ships a `ui/` directory without opting in via
        // the manifest is treated as UI-less (matches principle of least
        // surprise and avoids accidental custom-UI activation).
        let uiIndexURL: URL? = {
            guard manifest.ui != nil else { return nil }
            let url = rootURL.appendingPathComponent(manifest.uiEntryHTMLPath)
            return fileManager.fileExists(atPath: url.path) ? url : nil
        }()

        return .ok(PresetBundle(
            rootURL: rootURL,
            manifest: manifest,
            entryScriptURL: entryScriptURL,
            uiIndexURL: uiIndexURL,
            uiDirectoryURL: uiDirExists ? uiDirURL : nil
        ))
    }

    /// Convenience wrapper around `loadResult(from:)` for callers that only
    /// care about the success case. Returns `nil` for both `.notABundle`
    /// and `.broken` outcomes — use `loadResult(from:)` directly when you
    /// need to surface broken bundles distinctly.
    static func load(from rootURL: URL) -> PresetBundle? {
        if case .ok(let bundle) = loadResult(from: rootURL) { return bundle }
        return nil
    }

    /// Synthesize a bundle view of `rootURL` for repair purposes — succeeds
    /// even when `loadResult` would return `.broken`. Used by the preset
    /// browser when a user clicks a broken row to open `manifest.json` in
    /// the editor without going through the DSP load pipeline.
    ///
    /// When the manifest parses, the returned bundle uses the real one;
    /// otherwise it falls back to a minimal Python default manifest so
    /// `BundleFilePicker` still has a stable view of the bundle's editable
    /// files. The entry-script URL is computed from `manifest.entry`
    /// whether or not the file exists on disk — the editor reads its
    /// bytes lazily and tolerates a missing file.
    ///
    /// Returns nil only when `rootURL` isn't a directory.
    static func inspect(from rootURL: URL) -> PresetBundle? {
        let fileManager = FileManager.default
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }

        let manifestURL = rootURL.appendingPathComponent(PresetManifest.filename)
        let manifest: PresetManifest = {
            if let data = try? Data(contentsOf: manifestURL),
               let parsed = try? PresetManifest.decode(from: data) {
                return parsed
            }
            return PresetBundle.defaultManifest(language: .python, includeUI: false)
        }()

        let entryScriptURL = rootURL.appendingPathComponent(manifest.entry)

        let uiDirURL = rootURL.appendingPathComponent("ui", isDirectory: true)
        let uiDirExists: Bool = {
            var isD: ObjCBool = false
            return fileManager.fileExists(atPath: uiDirURL.path, isDirectory: &isD) && isD.boolValue
        }()

        let uiIndexURL: URL? = {
            guard manifest.ui != nil else { return nil }
            let url = rootURL.appendingPathComponent(manifest.uiEntryHTMLPath)
            return fileManager.fileExists(atPath: url.path) ? url : nil
        }()

        return PresetBundle(
            rootURL: rootURL,
            manifest: manifest,
            entryScriptURL: entryScriptURL,
            uiIndexURL: uiIndexURL,
            uiDirectoryURL: uiDirExists ? uiDirURL : nil
        )
    }

    /// Strip the `.cdp` extension from a bundle directory's last path
    /// component, for display in a list. Mirrors the `name` getter on a
    /// loaded bundle so broken bundles show up under the same display
    /// name they would have if they parsed.
    static func displayName(for rootURL: URL) -> String {
        let last = rootURL.lastPathComponent
        if last.hasSuffix(".\(bundleExtension)") {
            return String(last.dropLast(bundleExtension.count + 1))
        }
        return last
    }

    // MARK: - Detection

    /// A fast check: does this directory look like a preset bundle? True iff
    /// it contains a `manifest.json` file. Does not validate the manifest —
    /// cheap enough to call during directory enumeration.
    static func looksLikeBundle(at url: URL) -> Bool {
        let manifestURL = url.appendingPathComponent(PresetManifest.filename)
        return FileManager.default.fileExists(atPath: manifestURL.path)
    }

    /// Derived script language (delegates to the manifest).
    var language: ScriptLanguage { manifest.resolvedLanguage }

    /// Read the entry script's source text.
    func readSource() throws -> String {
        try String(contentsOf: entryScriptURL, encoding: .utf8)
    }

    /// Write updated source back to the entry script.
    func writeSource(_ source: String) throws {
        try source.write(to: entryScriptURL, atomically: true, encoding: .utf8)
    }
}

// MARK: - Scaffolding

extension PresetBundle {
    /// Suggested default manifest for a new bundle with the given language.
    /// Uses `PresetManifest.defaultScaffoldUI` so the existing-bundle
    /// re-save path in `PresetManager.savePreset` and this fresh-bundle
    /// path emit the same dimensions; drift between them was a thing
    /// before — see Failures #1 / #4 in the 2026-05-08 /try-it sweep.
    static func defaultManifest(language: ScriptLanguage, includeUI: Bool) -> PresetManifest {
        let entry = language == .rust ? "process.rs" : "process.py"
        return PresetManifest(
            schemaVersion: PresetManifest.currentSchemaVersion,
            entry: entry,
            language: language.rawValue,
            ui: includeUI ? PresetManifest.defaultScaffoldUI : nil,
            meta: nil
        )
    }

    /// Starter `ui/index.html` content used when scaffolding a new
    /// bundle with custom UI enabled. Leans on the injected `cdp-ui`
    /// component library — `<cdp-panel auto>` renders one appropriate
    /// control per parameter (slider / toggle / choice / etc.), matching
    /// the Swift stock panel's behavior. Authors can replace as little
    /// or as much as they want: drop in `<cdp-slider param="0">` or
    /// `<cdp-xy param-x="0" param-y="1">` alongside, or strip the
    /// panel entirely and hand-build a layout.
    static func starterIndexHTML() -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset="utf-8">
          <title>Custom UI</title>
          <style>
            :root { color-scheme: light dark; }
            html, body {
              margin: 0; padding: 0; height: 100%;
              font: 13px -apple-system, system-ui, sans-serif;
              background: Canvas; color: CanvasText;
            }
            .conjure-ui {
              display: flex; flex-direction: column;
              gap: 12px;
              padding: 12px;
            }
            cdp-slider { min-height: 24px; min-width: 100px; }
            cdp-knob   { min-width: 40px; min-height: 40px; }
            cdp-xy     { min-width: 80px; min-height: 80px; }
            cdp-toggle { min-height: 24px; min-width: 32px; }
            cdp-choice { min-height: 28px; min-width: 80px; }
            cdp-panel, cdp-slider, cdp-toggle, cdp-choice, cdp-xy, cdp-knob {
              --cdp-accent: currentColor;
            }
          </style>
        </head>
        <body>
          <main class="conjure-ui">
            <cdp-panel auto></cdp-panel>
            <!--
              Swap the line above for anything you want. Examples:
                <cdp-slider param="0"></cdp-slider>
                <cdp-toggle param="Bypass"></cdp-toggle>
                <cdp-choice param="Mode"></cdp-choice>
                <cdp-xy param-x="0" param-y="1"></cdp-xy>
                <cdp-knob param="cutoff"></cdp-knob>
              The library is documented at `window.ConjureDSP.ui` —
              primitives (ConjureDSP.ui.control(i), formatValue, ...) are
              available when you want to render your own widgets.
            -->
          </main>
        </body>
        </html>
        """
    }
}
