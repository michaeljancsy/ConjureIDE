import Foundation

/// Describes a single editable file inside a preset bundle. The editor's
/// file picker lists one of these per file, and the view-layer state
/// machine uses `kind` to pick the right Monaco language mode and decide
/// where writes should go.
struct BundleFileEntry: Identifiable, Hashable {
    /// Stable id keyed by path — lets `ForEach` diff cleanly when the user
    /// switches bundles.
    var id: String { url.path }

    /// Absolute URL on disk.
    let url: URL

    /// Relative path from the bundle root (e.g. `"process.py"`,
    /// `"ui/index.html"`, `"ui/assets/style.css"`). Shown in the picker.
    let relativePath: String

    /// What category of file this is. Drives language mode + save routing.
    let kind: Kind

    enum Kind: String {
        /// The DSP entry script named in `manifest.entry`. Saves go through
        /// the existing Run pipeline (compile + reload); the Run button
        /// stays meaningful only for this file.
        case entryScript
        /// `manifest.json`. Saves rewrite the manifest and refresh the
        /// bundle so e.g. UI width/height changes take effect.
        case manifest
        /// HTML/JS/CSS/JSON under `ui/`. Saves write bytes directly; the
        /// FSEventStream-based hot-reload picks up the change and flips
        /// the webview automatically.
        case uiAsset
    }
}

/// Builds the ordered list of editable files for a bundle. Used by the
/// in-plugin editor's file picker. The ordering is deterministic so the
/// picker doesn't jump around when users switch presets: entry script
/// first, manifest second, UI files alphabetically after.
enum BundleFilePickerEntries {
    /// Editable text extensions. Binary payloads (images, fonts) are
    /// filtered out — the editor can't represent them and the picker
    /// would just produce dead options.
    static let editableExtensions: Set<String> = [
        "html", "htm",
        "js", "mjs",
        "css",
        "json",
        "txt", "md",
        "svg",
    ]

    /// Enumerate the bundle's text files in display order. The bundle
    /// must already be loaded; caller passes in the parsed
    /// `PresetBundle` rather than a raw URL so the entry script's name
    /// lines up with `manifest.entry` without re-parsing.
    static func entries(for bundle: PresetBundle) -> [BundleFileEntry] {
        var result: [BundleFileEntry] = []

        // 1. Entry script (process.py / process.rs) — first so the
        //    default picker selection matches today's behavior.
        let entryRelative = bundle.manifest.entry
        result.append(BundleFileEntry(
            url: bundle.entryScriptURL,
            relativePath: entryRelative,
            kind: .entryScript
        ))

        // 2. Manifest — always present (a bundle without one doesn't load).
        result.append(BundleFileEntry(
            url: bundle.rootURL.appendingPathComponent(PresetManifest.filename),
            relativePath: PresetManifest.filename,
            kind: .manifest
        ))

        // 3. UI files under ui/, alphabetically by relative path so
        //    index.html sorts near the top.
        if let uiDir = bundle.uiDirectoryURL {
            let uiFiles = discoverEditableFiles(under: uiDir, relativeTo: bundle.rootURL)
            result.append(contentsOf: uiFiles.sorted { $0.relativePath < $1.relativePath })
        }

        return result
    }

    /// Recursively enumerate `directory`, yielding an entry for every
    /// text file with a recognized extension. Relative paths are
    /// computed against `rootURL` so callers get e.g. `"ui/index.html"`
    /// rather than an absolute path.
    private static func discoverEditableFiles(
        under directory: URL, relativeTo rootURL: URL
    ) -> [BundleFileEntry] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var out: [BundleFileEntry] = []
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            guard editableExtensions.contains(ext) else { continue }
            let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            guard isRegular else { continue }

            // Standardize both URLs before diffing — file URLs on macOS
            // can have `/private` prefixes that break a naive string
            // drop.
            let rootPath = rootURL.standardizedFileURL.path
            let filePath = url.standardizedFileURL.path
            guard filePath.hasPrefix(rootPath + "/") else { continue }
            let relative = String(filePath.dropFirst(rootPath.count + 1))
            out.append(BundleFileEntry(
                url: url,
                relativePath: relative,
                kind: .uiAsset
            ))
        }
        return out
    }
}

extension BundleFileEntry {
    /// Monaco language identifier matching this file's extension. Returns
    /// `"plaintext"` as a safe fallback; Monaco accepts unknown values.
    var monacoLanguageID: String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "py":                     return "python"
        case "rs":                     return "rust"
        case "html", "htm":            return "html"
        case "js", "mjs":              return "javascript"
        case "css":                    return "css"
        case "json":                   return "json"
        case "md":                     return "markdown"
        case "svg":                    return "xml"
        default:                       return "plaintext"
        }
    }
}
