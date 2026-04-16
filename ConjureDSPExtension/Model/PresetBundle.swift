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

    /// Attempt to load a bundle from a directory. Returns `nil` if the URL
    /// does not point to a valid bundle (missing manifest, missing entry
    /// script, or unreadable manifest).
    static func load(from rootURL: URL) -> PresetBundle? {
        let fileManager = FileManager.default
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }

        let manifestURL = rootURL.appendingPathComponent(PresetManifest.filename)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return nil
        }

        let manifest: PresetManifest
        do {
            let data = try Data(contentsOf: manifestURL)
            manifest = try PresetManifest.decode(from: data)
        } catch {
            log.error("Failed to decode manifest at \(manifestURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }

        let entryScriptURL = rootURL.appendingPathComponent(manifest.entry)
        guard fileManager.fileExists(atPath: entryScriptURL.path) else {
            log.error("Entry script missing at \(entryScriptURL.path, privacy: .public)")
            return nil
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

        return PresetBundle(
            rootURL: rootURL,
            manifest: manifest,
            entryScriptURL: entryScriptURL,
            uiIndexURL: uiIndexURL,
            uiDirectoryURL: uiDirExists ? uiDirURL : nil
        )
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
    static func defaultManifest(language: ScriptLanguage, includeUI: Bool) -> PresetManifest {
        let entry = language == .rust ? "process.rs" : "process.py"
        return PresetManifest(
            schemaVersion: PresetManifest.currentSchemaVersion,
            entry: entry,
            language: language.rawValue,
            ui: includeUI ? PresetManifest.UI(
                entryHTML: "ui/index.html",
                width: 520,
                height: 260,
                fps: 30,
                audioFrames: false
            ) : nil,
            meta: nil
        )
    }

    /// Starter `ui/index.html` content used when scaffolding a new bundle with
    /// custom UI enabled. Renders a simple labeled slider per parameter by
    /// delegating to the `ConjureDSP.parameters` API. Authors are expected to
    /// replace this with their own layout.
    static func starterIndexHTML() -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta http-equiv="Content-Security-Policy"
                content="default-src 'self' 'unsafe-inline'; connect-src 'none'; img-src 'self' data:;">
          <title>Custom UI</title>
          <style>
            :root { color-scheme: light dark; }
            html, body { margin: 0; padding: 0; font: 12px -apple-system, system-ui, sans-serif; }
            body { padding: 12px; background: Canvas; color: CanvasText; }
            .row { display: flex; align-items: center; gap: 12px; margin-bottom: 8px; }
            .row label { flex: 0 0 120px; }
            .row input[type=range] { flex: 1 1 auto; }
            .row .val { flex: 0 0 72px; text-align: right; font-variant-numeric: tabular-nums; }
          </style>
        </head>
        <body>
          <div id="rows"></div>
          <script>
            const CDP = window.ConjureDSP;
            function render() {
              const host = document.getElementById('rows');
              host.innerHTML = '';
              const n = CDP.parameters.count;
              for (let i = 0; i < n; i++) {
                const m = CDP.parameters.metadata(i);
                const row = document.createElement('div'); row.className = 'row';
                const lbl = document.createElement('label'); lbl.textContent = m.name || ('Param ' + i);
                const rng = document.createElement('input'); rng.type = 'range';
                rng.min = m.min ?? 0; rng.max = m.max ?? 1;
                rng.step = (m.style === 'integer' || m.style === 'choice') ? 1 : ((m.max - m.min) / 1000);
                rng.value = CDP.parameters.get(i);
                const val = document.createElement('span'); val.className = 'val';
                val.textContent = Number(rng.value).toFixed(2) + (m.unit ? ' ' + m.unit : '');
                rng.addEventListener('input', () => {
                  CDP.parameters.set(i, parseFloat(rng.value));
                  val.textContent = Number(rng.value).toFixed(2) + (m.unit ? ' ' + m.unit : '');
                });
                CDP.parameters.onChange(i, (v) => {
                  rng.value = v;
                  val.textContent = Number(v).toFixed(2) + (m.unit ? ' ' + m.unit : '');
                });
                row.append(lbl, rng, val); host.append(row);
              }
            }
            if (CDP && CDP.ready) { CDP.ready(render); } else { window.addEventListener('ConjureDSPReady', render); }
          </script>
        </body>
        </html>
        """
    }
}
