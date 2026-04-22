import Foundation

/// Static validation for a preset bundle's custom UI.
///
/// Runs a set of cheap text-based checks over `manifest.json` + `ui/index.html`
/// that catch the most common ways a custom UI ships broken: unresolved
/// `param=` references, external network fetches that the scheme handler's CSP
/// will block, missing manifest `ui` block, canvas 2D using CSS system colors
/// it can't parse, and UIs that declare parameters but expose zero controls.
///
/// The validator is intentionally forgiving — it treats the HTML as plain text
/// (regex scans, not a real parser) because preset UIs are small and authors
/// use inline script/style tags that full parsers choke on. False positives are
/// preferable to false negatives: the agent can always disagree with an
/// individual warning, but it can't recover from a silently-broken ship.
///
/// Exposed to the MCP layer so `write_bundle_file` can surface warnings in the
/// same turn the file is written, and `validate_bundle` can re-run the full
/// sweep on demand.
enum BundleUIValidator {

    enum Severity: String, Encodable {
        case warn
        case fail
    }

    struct Issue: Encodable, Equatable {
        let severity: Severity
        /// Short identifier for the check, e.g. `"params_referenced_in_ui"`.
        /// Stable — the agent can pattern-match on these to suppress noise.
        let check: String
        /// File path (bundle-relative) where the issue lives, when applicable.
        let file: String?
        let message: String
        /// Optional one-liner pointing at the fix.
        let suggestion: String?
    }

    struct Report: Encodable {
        let status: ReportStatus
        let issues: [Issue]
    }

    enum ReportStatus: String, Encodable {
        case pass   // no issues
        case warn   // only warnings
        case fail   // at least one fail
    }

    // MARK: - Entry point

    /// Run every check against the given bundle. Always returns a `Report`
    /// even for bundles without a custom UI — they just get `status: .pass`
    /// and no issues (nothing to validate).
    static func validate(_ bundle: PresetBundle) -> Report {
        var issues: [Issue] = []

        // A bundle without any UI intent has nothing to validate — the
        // stock slider panel renders for it either way. "UI intent" =
        // either the manifest declares a ui block OR there's a physical
        // ui/index.html on disk. Check the file system directly since
        // `bundle.uiIndexURL` is nil when the manifest has no ui block
        // even if the file exists (that's the orphan case we want to
        // flag, not skip).
        let hasUIBlock = bundle.manifest.ui != nil
        let defaultIndexPath = bundle.rootURL
            .appendingPathComponent("ui")
            .appendingPathComponent("index.html")
            .path
        let hasIndexOnDisk = FileManager.default.fileExists(atPath: defaultIndexPath)
        guard hasUIBlock || hasIndexOnDisk else {
            return Report(status: .pass, issues: [])
        }

        issues.append(contentsOf: checkManifestUIBlock(bundle))
        issues.append(contentsOf: checkEntryHTMLResolves(bundle))
        issues.append(contentsOf: checkSchemaV2Recommended(bundle))

        // HTML-dependent checks. Prefer the manifest-declared entry
        // (via `bundle.uiIndexURL`); fall back to the default `ui/index.html`
        // path so orphan-file bundles (no ui block in manifest, file on disk)
        // still get their HTML linted — the manifest_ui_block_missing check
        // flags the orphan, but the HTML may also have param typos, CSP
        // violations, etc. worth surfacing alongside it.
        let htmlURL: URL? = bundle.uiIndexURL ?? (hasIndexOnDisk
            ? URL(fileURLWithPath: defaultIndexPath)
            : nil)
        if let url = htmlURL,
           let html = try? String(contentsOf: url, encoding: .utf8) {
            issues.append(contentsOf: checkParamReferences(html: html, bundle: bundle))
            issues.append(contentsOf: checkNoExternalNetwork(html: html))
            issues.append(contentsOf: checkNoSystemColorInCanvas(html: html))
            issues.append(contentsOf: checkHasInteractiveSurface(html: html, bundle: bundle))
        }

        let status: ReportStatus
        if issues.contains(where: { $0.severity == .fail }) {
            status = .fail
        } else if !issues.isEmpty {
            status = .warn
        } else {
            status = .pass
        }
        return Report(status: status, issues: issues)
    }

    // MARK: - Individual checks

    /// ui/index.html exists on disk but the manifest doesn't advertise a ui
    /// block — the plugin falls back to stock sliders and the author's UI
    /// file is ignored. Always a fail because there's no ambiguity.
    private static func checkManifestUIBlock(_ bundle: PresetBundle) -> [Issue] {
        let indexURL = bundle.rootURL
            .appendingPathComponent("ui")
            .appendingPathComponent("index.html")
        let indexExists = FileManager.default.fileExists(atPath: indexURL.path)
        guard indexExists, bundle.manifest.ui == nil else { return [] }
        return [
            Issue(
                severity: .fail,
                check: "manifest_ui_block_missing",
                file: PresetManifest.filename,
                message: "ui/index.html exists but manifest.json has no \"ui\" block — the plugin will render stock sliders and ignore the HTML.",
                suggestion: #"Add a "ui" block to manifest.json, e.g. {"entryHTML": "ui/index.html", "width": 520, "height": 380, "fps": 30, "audioFrames": false}."#
            )
        ]
    }

    /// manifest.ui.entryHTML must point at a real file inside the bundle.
    /// Typo here silently disables the custom UI.
    private static func checkEntryHTMLResolves(_ bundle: PresetBundle) -> [Issue] {
        // manifest.ui.entryHTML is itself optional; fall back to the same
        // default the manifest uses when rendering (`ui/index.html`).
        guard bundle.manifest.ui != nil else { return [] }
        let entryPath = bundle.manifest.uiEntryHTMLPath
        let entryURL = bundle.rootURL.appendingPathComponent(entryPath)
        guard !FileManager.default.fileExists(atPath: entryURL.path) else { return [] }
        return [
            Issue(
                severity: .fail,
                check: "ui_entry_html_missing",
                file: PresetManifest.filename,
                message: "manifest.ui.entryHTML points at \"\(entryPath)\" but that file doesn't exist in the bundle.",
                suggestion: "Either create the file via write_bundle_file, or update manifest.ui.entryHTML to match an existing path."
            )
        ]
    }

    /// Using schemaVersion 1 for a bundle with a custom UI means param
    /// metadata is only available after the DSP compiles. For Rust presets
    /// that's a long cold-load during which the UI renders with placeholder
    /// defaults. v2 + params: [...] solves it.
    private static func checkSchemaV2Recommended(_ bundle: PresetBundle) -> [Issue] {
        guard bundle.manifest.schemaVersion == 1 else { return [] }
        return [
            Issue(
                severity: .warn,
                check: "schema_v2_recommended",
                file: PresetManifest.filename,
                message: "schemaVersion is 1 — custom UI will render with placeholder defaults until the DSP compiles. For Rust presets this is a multi-second cold-load.",
                suggestion: "Upgrade to schemaVersion 2 and declare a params: [...] array in the manifest. See get_docs(\"ui\")."
            )
        ]
    }

    /// Every `param="X"`, `param-x="X"`, `param-y="X"` attribute in the UI
    /// must resolve to a parameter in the manifest (or, as a last resort,
    /// a numeric index string). Loose match mirrors cdp-ui.js: ignore
    /// case, underscores, and spaces.
    private static func checkParamReferences(html: String, bundle: PresetBundle) -> [Issue] {
        guard let declared = bundle.manifest.params, !declared.isEmpty else {
            // No params in the manifest — we can't check references against
            // anything. Not an error; legacy presets fall through here.
            return []
        }
        let declaredNorms = Set(declared.map { looseNormalize($0.name) })

        var issues: [Issue] = []
        let attrRegex = try? NSRegularExpression(
            pattern: #"param(?:-x|-y)?\s*=\s*["']([^"']+)["']"#,
            options: []
        )
        guard let regex = attrRegex else { return [] }
        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var seenUnresolved: Set<String> = []
        for match in matches where match.numberOfRanges >= 2 {
            let value = ns.substring(with: match.range(at: 1))
            // Numeric index like "0" is a valid way to bind — only flag names.
            if Int(value) != nil { continue }
            let norm = looseNormalize(value)
            if declaredNorms.contains(norm) { continue }
            if seenUnresolved.contains(value) { continue }
            seenUnresolved.insert(value)
            let nearest = nearestDeclaredName(to: value, declared: declared)
            issues.append(
                Issue(
                    severity: .fail,
                    check: "params_referenced_in_ui",
                    file: "ui/index.html",
                    message: "param=\"\(value)\" doesn't match any manifest.params[].name.",
                    suggestion: nearest.map { "Did you mean \"\($0)\"?" } ?? "Add the param to manifest.params, or bind to an existing name."
                )
            )
        }
        return issues
    }

    /// The custom UI webview runs with a strict CSP that blocks fetch, XHR,
    /// WebSocket, and any non-bundle script/link. Flag the common ways the
    /// agent forgets and produces UIs that look fine in the HTML but fail
    /// silently at runtime.
    private static func checkNoExternalNetwork(html: String) -> [Issue] {
        var issues: [Issue] = []

        // External <script src>, <link href>, <img src> (absolute URLs only;
        // relative refs go through the scheme handler, which is fine).
        let externalRefPattern = #"<(script|link|img|iframe|audio|video|source)\b[^>]*\s(?:src|href)\s*=\s*["'](?:https?:|//|data:font|ftp:|ws:|wss:)([^"']+)["']"#
        if let regex = try? NSRegularExpression(pattern: externalRefPattern, options: [.caseInsensitive]) {
            let ns = html as NSString
            let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
            for match in matches where match.numberOfRanges >= 2 {
                let tag = ns.substring(with: match.range(at: 1))
                issues.append(
                    Issue(
                        severity: .fail,
                        check: "external_asset_ref",
                        file: "ui/index.html",
                        message: "<\(tag)> references an external URL; the custom-UI CSP only allows assets bundled inside the preset.",
                        suggestion: "Inline the code/style, or ship the asset under ui/assets/ and reference it with a relative path."
                    )
                )
            }
        }

        // fetch / XMLHttpRequest / WebSocket in inline script.
        let egressChecks: [(String, String, String)] = [
            (#"\bfetch\s*\("#, "fetch call", "connect-src 'none' in the CSP blocks fetch."),
            (#"\bnew\s+XMLHttpRequest\s*\("#, "XMLHttpRequest", "connect-src 'none' blocks XHR."),
            (#"\bnew\s+WebSocket\s*\("#, "WebSocket", "connect-src 'none' blocks WebSockets."),
            (#"\bnew\s+EventSource\s*\("#, "EventSource", "connect-src 'none' blocks EventSource."),
        ]
        for (pattern, label, detail) in egressChecks {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               regex.firstMatch(in: html, range: NSRange(location: 0, length: (html as NSString).length)) != nil {
                issues.append(
                    Issue(
                        severity: .fail,
                        check: "network_egress_in_ui",
                        file: "ui/index.html",
                        message: "Custom UI contains \(label) — \(detail)",
                        suggestion: "Remove the network call, or ship the data it would fetch as a bundled asset."
                    )
                )
            }
        }

        return issues
    }

    /// Canvas 2D can't parse CSS system color keywords (`CanvasText`,
    /// `Canvas`) or `color-mix()`. Assigning them to fillStyle/strokeStyle
    /// silently fails (the canvas falls back to black). The docs recommend
    /// a getComputedStyle probe pattern. Flag the literal assignments.
    private static func checkNoSystemColorInCanvas(html: String) -> [Issue] {
        var issues: [Issue] = []
        let pattern = #"(?:fillStyle|strokeStyle)\s*=\s*["'](CanvasText|Canvas|color-mix\([^"']*\))["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var seen = Set<String>()
        for match in matches where match.numberOfRanges >= 2 {
            let value = ns.substring(with: match.range(at: 1))
            if seen.contains(value) { continue }
            seen.insert(value)
            issues.append(
                Issue(
                    severity: .warn,
                    check: "canvas_system_color_literal",
                    file: "ui/index.html",
                    message: "Canvas 2D fillStyle/strokeStyle can't parse \"\(value)\" — it falls back to black, defeating the theme-aware color intent.",
                    suggestion: "Resolve system colors via a hidden probe: `const probe = document.createElement('span'); probe.style.color = 'CanvasText'; document.body.appendChild(probe); const c = getComputedStyle(probe).color;`. See get_docs(\"ui\")."
                )
            )
        }
        return issues
    }

    /// A custom UI that declares parameters but contains no interactive
    /// components leaves users without a way to change any of them. Flag
    /// when the HTML has zero cdp-* controls, zero <input type="range">,
    /// and no <cdp-panel auto> fallback.
    private static func checkHasInteractiveSurface(html: String, bundle: PresetBundle) -> [Issue] {
        guard let params = bundle.manifest.params, !params.isEmpty else { return [] }

        let interactiveTags = ["cdp-slider", "cdp-toggle", "cdp-choice", "cdp-xy", "cdp-panel"]
        let foundInteractiveTag = interactiveTags.contains { tag in
            html.range(of: "<\(tag)", options: .caseInsensitive) != nil
        }
        let foundRangeInput = html.range(of: #"<input[^>]+type\s*=\s*["']range["']"#, options: .regularExpression) != nil

        if foundInteractiveTag || foundRangeInput { return [] }

        return [
            Issue(
                severity: .warn,
                check: "no_interactive_surface",
                file: "ui/index.html",
                message: "UI has \(params.count) declared parameter\(params.count == 1 ? "" : "s") but no cdp-slider / cdp-toggle / cdp-choice / cdp-xy / cdp-panel / <input type=\"range\"> — users will have no way to change them.",
                suggestion: "Add per-param controls, or drop in <cdp-panel auto></cdp-panel> as a catch-all. Fully decorative UIs are fine for display-only presets, but every parameter should have at least one way to be edited."
            )
        ]
    }

    // MARK: - Helpers

    /// Case-insensitive, underscore-and-space-insensitive comparison key.
    /// Mirrors the loose matching cdp-ui.js uses when resolving `param="…"`
    /// attributes against manifest metadata names, so this validator
    /// produces the same resolution result the webview would.
    private static func looseNormalize(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
    }

    /// Pick the closest declared param name by simple Levenshtein, used
    /// for "did you mean" suggestions. Only suggests when the distance is
    /// small enough that it's plausibly a typo.
    private static func nearestDeclaredName(
        to query: String,
        declared: [PresetManifest.ParamDecl]
    ) -> String? {
        let qn = looseNormalize(query)
        var best: (name: String, dist: Int)?
        for p in declared {
            let d = levenshtein(qn, looseNormalize(p.name))
            if best == nil || d < best!.dist {
                best = (p.name, d)
            }
        }
        guard let winner = best, winner.dist <= max(2, query.count / 3) else { return nil }
        return winner.name
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let ac = Array(a), bc = Array(b)
        if ac.isEmpty { return bc.count }
        if bc.isEmpty { return ac.count }
        var prev = Array(0...bc.count)
        var curr = Array(repeating: 0, count: bc.count + 1)
        for i in 1...ac.count {
            curr[0] = i
            for j in 1...bc.count {
                let cost = ac[i - 1] == bc[j - 1] ? 0 : 1
                curr[j] = min(curr[j - 1] + 1, prev[j] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[bc.count]
    }
}
