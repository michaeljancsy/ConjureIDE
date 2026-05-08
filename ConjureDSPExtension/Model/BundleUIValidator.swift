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

        // Default-out-of-range is checked regardless of UI intent — even a
        // generic-slider preset stores a wrong default if the script
        // declared one outside [min, max]. The AU's denormalize clamps,
        // so the bundle still loads, but the slider's initial position
        // doesn't match what the author intended (caught Round 9 of the
        // agent UX experiment: `mix(default=100.0)` clamped to 1.0
        // silently because the agent confused the 0..1 mix range with
        // the 0..100 pct range).
        issues.append(contentsOf: checkParamDefaultsInRange(bundle))

        // A bundle without any UI intent has nothing else to validate —
        // the stock slider panel renders for it either way. "UI intent"
        // = either the manifest declares a ui block OR there's a
        // physical ui/index.html on disk. Check the file system
        // directly since `bundle.uiIndexURL` is nil when the manifest
        // has no ui block even if the file exists (that's the orphan
        // case we want to flag, not skip).
        let hasUIBlock = bundle.manifest.ui != nil
        let defaultIndexPath = bundle.rootURL
            .appendingPathComponent("ui")
            .appendingPathComponent("index.html")
            .path
        let hasIndexOnDisk = FileManager.default.fileExists(atPath: defaultIndexPath)
        guard hasUIBlock || hasIndexOnDisk else {
            return Self.report(from: issues)
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
            issues.append(contentsOf: checkUnboundDeclaredParams(html: html, bundle: bundle))
            issues.append(contentsOf: checkTelemetryReferences(html: html, bundle: bundle))
            issues.append(contentsOf: checkStateReferences(html: html, bundle: bundle))
            issues.append(contentsOf: checkNoExternalNetwork(html: html))
            issues.append(contentsOf: checkNoSystemColorInCanvas(html: html))
            issues.append(contentsOf: checkHasInteractiveSurface(html: html, bundle: bundle))
            issues.append(contentsOf: checkTextContrast(html: html))
            issues.append(contentsOf: checkColorSchemeDeclared(html: html))
        }

        return Self.report(from: issues)
    }

    /// Build a `Report` whose status reflects the worst-severity issue.
    /// Pulled out so the early-return path (no UI intent) and the full
    /// path can both ship the same status-derivation rule.
    private static func report(from issues: [Issue]) -> Report {
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
    ///
    /// Severity is tactically split: a manifest that declares
    /// entryHTML but ships an empty (or HTML-less) `ui/` directory is
    /// almost always mid-authoring — the standard sequence is
    /// save_preset → write manifest.json → write ui/index.html, and
    /// the manifest write transiently fails this check until the next
    /// call. Reporting `fail` there spooks literal-minded agents.
    /// Reserve `fail` for the case that's unambiguously a bug: the
    /// `ui/` directory has other html files (the author shipped some
    /// HTML), but the entryHTML name typoed and references a file
    /// that isn't among them.
    private static func checkEntryHTMLResolves(_ bundle: PresetBundle) -> [Issue] {
        // manifest.ui.entryHTML is itself optional; fall back to the same
        // default the manifest uses when rendering (`ui/index.html`).
        guard bundle.manifest.ui != nil else { return [] }
        let entryPath = bundle.manifest.uiEntryHTMLPath
        let entryURL = bundle.rootURL.appendingPathComponent(entryPath)
        guard !FileManager.default.fileExists(atPath: entryURL.path) else { return [] }

        // Look at ui/ to decide severity. `ui/` may not exist at all
        // (manifest written first, no ui dir created yet) — that's
        // also the transient "still authoring" case.
        let uiDir = bundle.rootURL.appendingPathComponent("ui", isDirectory: true)
        let fm = FileManager.default
        let uiHTMLFiles: [String] = {
            guard let entries = try? fm.contentsOfDirectory(
                at: uiDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { return [] }
            return entries
                .filter { $0.pathExtension.lowercased() == "html" }
                .map { $0.lastPathComponent }
        }()

        if uiHTMLFiles.isEmpty {
            // No HTML in ui/ yet — author hasn't gotten there. Warn,
            // don't fail. The next write_bundle_file('ui/index.html',
            // ...) will resolve the issue and a subsequent
            // validate_bundle pass will return clean.
            return [
                Issue(
                    severity: .warn,
                    check: "ui_entry_html_missing",
                    file: PresetManifest.filename,
                    message: "manifest.ui.entryHTML points at \"\(entryPath)\" but ui/ contains no HTML files yet.",
                    suggestion: "If you're mid-authoring, this resolves once you call write_bundle_file with the entryHTML file. Otherwise update manifest.ui.entryHTML or write the missing file."
                )
            ]
        }

        // ui/ has HTML, just not the one named — almost certainly a
        // typo. Real failure.
        let nearby = uiHTMLFiles.sorted().joined(separator: ", ")
        return [
            Issue(
                severity: .fail,
                check: "ui_entry_html_missing",
                file: PresetManifest.filename,
                message: "manifest.ui.entryHTML points at \"\(entryPath)\" but that file doesn't exist. ui/ contains: \(nearby).",
                suggestion: "Update manifest.ui.entryHTML to match one of the existing files, or rename the file on disk."
            )
        ]
    }

    /// Each declared param's `default` must lie within `[min, max]`.
    /// Defaults outside the declared range are clamped silently by the
    /// AU's denormalize — the bundle loads, audio runs, but the slider's
    /// initial position doesn't reflect what the author wrote.
    /// Almost always indicates a unit confusion (e.g. mix() at 100 when
    /// the author meant pct() at 100). Warn rather than fail because
    /// older bundles in the wild may have minor drift; surfacing it via
    /// validate_bundle and inline write_bundle_file is enough to nudge
    /// authors to fix it on the next save.
    private static func checkParamDefaultsInRange(_ bundle: PresetBundle) -> [Issue] {
        guard let params = bundle.manifest.params, !params.isEmpty else {
            return []
        }
        var issues: [Issue] = []
        for p in params {
            // Allow tiny float drift — IEEE float comparison around the
            // boundary can flag a default that's computed from the same
            // min/max literals. 1e-4 is invisibly small in any real
            // parameter range.
            let tol: Float = 1e-4
            if p.default < p.min - tol || p.default > p.max + tol {
                issues.append(Issue(
                    severity: .warn,
                    check: "param_default_out_of_range",
                    file: PresetManifest.filename,
                    message: "Param '\(p.name)' has default \(p.default) outside its declared range [\(p.min), \(p.max)]. The AU silently clamps to the boundary; the slider's initial position won't match author intent.",
                    suggestion: "Did you confuse two builders? mix() is 0..1, pct() is 0..100. Adjust the default to a value within [\(p.min), \(p.max)]."
                ))
            }
        }
        return issues
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
    ///
    /// When `manifest.params` is nil or empty, named references can't be
    /// resolved against anything AT ALL — the components will render with
    /// "unknown" labels and no user-visible way to bind them, even after
    /// the DSP compiles (resolveParamAttr doesn't late-bind to DSP-
    /// extracted metadata by name, only by index). Flag that explicitly
    /// so the agent adds a manifest.params block.
    private static func checkParamReferences(html: String, bundle: PresetBundle) -> [Issue] {
        var issues: [Issue] = []
        let attrRegex = try? NSRegularExpression(
            pattern: #"param(?:-x|-y)?\s*=\s*["']([^"']+)["']"#,
            options: []
        )
        guard let regex = attrRegex else { return [] }
        // Strip HTML comments first — the starter scaffold lists example
        // bindings like `<cdp-toggle param="Bypass">` inside `<!-- ... -->`
        // for authors to copy. Those aren't real bindings; flagging them
        // wastes the agent's turn rewriting the comment.
        let scanned = stripHTMLComments(html)
        let ns = scanned as NSString
        let matches = regex.matches(in: scanned, range: NSRange(location: 0, length: ns.length))

        // Collect every named (non-numeric) reference in the HTML so the
        // two branches below can reason about them.
        var namedRefs: [String] = []
        for match in matches where match.numberOfRanges >= 2 {
            let value = ns.substring(with: match.range(at: 1))
            if Int(value) != nil { continue }  // numeric index binds don't need a name lookup
            namedRefs.append(value)
        }

        // Branch 1: no manifest.params. Any named reference is unresolvable.
        let declared = bundle.manifest.params ?? []
        guard !declared.isEmpty else {
            guard !namedRefs.isEmpty else { return [] }
            let unique = Array(Set(namedRefs)).sorted()
            let preview = unique.prefix(3).map { "\"\($0)\"" }.joined(separator: ", ")
            let andMore = unique.count > 3 ? " and \(unique.count - 3) more" : ""
            issues.append(
                Issue(
                    severity: .fail,
                    check: "params_referenced_in_ui",
                    file: "ui/index.html",
                    message: "UI has \(unique.count) named param reference\(unique.count == 1 ? "" : "s") (\(preview)\(andMore)) but manifest.json has no `params` block — every component that looks these up will render with an \"unknown\" label and stay disabled.",
                    suggestion: "Add a `params: [{name, min, max, default, unit?, curve?, ...}]` array to manifest.json (schema v2). See get_docs(\"ui\")."
                )
            )
            return issues
        }

        // Branch 2: manifest.params exists. Flag each name that doesn't
        // match a declared param (loose match).
        let declaredNorms = Set(declared.map { looseNormalize($0.name) })
        var seenUnresolved: Set<String> = []
        for value in namedRefs {
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

    /// Inverse of `checkParamReferences`: every parameter the manifest
    /// declares should have at least one binding in the UI (cdp-* `param=`
    /// attribute or a numeric-index `cdp-panel auto`). Surfaces the case
    /// where the agent compiled new DSP that adds a param but forgot to
    /// extend ui/index.html — the param tree rebuilds correctly, the
    /// stock slider panel + DAW automation see all params, but the
    /// custom UI silently renders only the old subset.
    ///
    /// Skips:
    ///   - bundles with no manifest.params (legacy / undeclared — nothing
    ///     to compare against)
    ///   - bundles whose UI uses `<cdp-panel auto>` (catch-all that
    ///     auto-renders one control per declared param)
    ///
    /// Severity is `fail`: every declared parameter must be reachable
    /// from the custom UI. If a param shouldn't be user-editable, drop
    /// it from `manifest.params` rather than declaring it and hiding it.
    private static func checkUnboundDeclaredParams(html: String, bundle: PresetBundle) -> [Issue] {
        guard let declared = bundle.manifest.params, !declared.isEmpty else { return [] }

        let scanned = stripHTMLComments(html)

        // <cdp-panel auto> is a catch-all renderer; presence implies all
        // declared params have a fallback control. Don't warn.
        if scanned.range(of: #"<cdp-panel\b[^>]*\bauto\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return []
        }

        // Collect every named or numeric `param=` reference in the UI.
        let attrRegex = try? NSRegularExpression(
            pattern: #"param(?:-x|-y)?\s*=\s*["']([^"']+)["']"#,
            options: []
        )
        guard let regex = attrRegex else { return [] }
        let ns = scanned as NSString
        let matches = regex.matches(in: scanned, range: NSRange(location: 0, length: ns.length))

        // Build the set of declared-param identifiers that the UI actually
        // touches. Index references resolve to the declared params at
        // that position; named references resolve via loose match.
        var boundIndices: Set<Int> = []
        let declaredNorms: [String] = declared.map { looseNormalize($0.name) }
        for match in matches where match.numberOfRanges >= 2 {
            let value = ns.substring(with: match.range(at: 1))
            if let idx = Int(value), idx >= 0, idx < declared.count {
                boundIndices.insert(idx)
                continue
            }
            let norm = looseNormalize(value)
            if let idx = declaredNorms.firstIndex(of: norm) {
                boundIndices.insert(idx)
            }
            // Unresolved named refs are flagged by checkParamReferences;
            // here we only care about the positive (which params ARE bound).
        }

        // Anything declared but not bound is an unbound param.
        var unbound: [String] = []
        for (idx, param) in declared.enumerated() where !boundIndices.contains(idx) {
            unbound.append(param.name)
        }
        if unbound.isEmpty { return [] }

        let preview = unbound.prefix(3).map { "\"\($0)\"" }.joined(separator: ", ")
        let andMore = unbound.count > 3 ? " and \(unbound.count - 3) more" : ""
        return [
            Issue(
                severity: .fail,
                check: "param_no_ui_binding",
                file: "ui/index.html",
                message: "manifest declares \(declared.count) param\(declared.count == 1 ? "" : "s") but the UI binds only \(declared.count - unbound.count) — \(unbound.count) param\(unbound.count == 1 ? " is" : "s are") not reachable from the custom UI: \(preview)\(andMore).",
                suggestion: "Add a `<cdp-slider param=\"\(unbound[0])\">` (or appropriate widget) for each missing param, OR drop in `<cdp-panel auto></cdp-panel>` as a catch-all. If the param shouldn't be user-editable, remove it from manifest.params rather than declaring it and hiding it."
            )
        ]
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

        let interactiveTags = ["cdp-slider", "cdp-toggle", "cdp-choice", "cdp-xy", "cdp-knob", "cdp-panel"]
        let foundInteractiveTag = interactiveTags.contains { tag in
            html.range(of: "<\(tag)", options: .caseInsensitive) != nil
        }
        let foundRangeInput = html.range(of: #"<input[^>]+type\s*=\s*["']range["']"#, options: .regularExpression) != nil

        if foundInteractiveTag || foundRangeInput { return [] }

        return [
            Issue(
                severity: .fail,
                check: "no_interactive_surface",
                file: "ui/index.html",
                message: "UI has \(params.count) declared parameter\(params.count == 1 ? "" : "s") but no cdp-slider / cdp-toggle / cdp-choice / cdp-xy / cdp-knob / cdp-panel / <input type=\"range\"> — users will have no way to change them.",
                suggestion: "Add per-param controls, or drop in <cdp-panel auto></cdp-panel> as a catch-all. Every declared parameter must be reachable from the UI."
            )
        ]
    }

    /// Scan the UI for text whose color and background are both dark
    /// or both light — unreadable. Four sub-checks:
    ///
    /// 1. Inline `style="color: X; background[-color]: Y; …"` pairs on
    ///    the same element. Uses the WCAG 2.1 contrast ratio with a
    ///    threshold of 3.0 (AA for large text, deliberately lenient to
    ///    avoid false positives on buttons with subtle hover tints).
    /// 2. CSS rule blocks inside `<style>` tags that declare both color
    ///    and background on the same selector. Same threshold.
    /// 3. **Cascaded pair check**: when a rule declares `color` but no
    ///    `background`, pair it with the body/html/:root's effective
    ///    background (or vice versa). Catches the common pattern of
    ///    `body { background: #0a0a0a; }` paired with `.label { color:
    ///    #555; }` in a separate rule — each rule is individually fine
    ///    by the pair-in-same-block check, but the effective text-on-
    ///    background combination is unreadable.
    /// 4. Theme-breaking hard-coded body color: if `body` declares
    ///    `color: white` / `#fff` (or analogous near-max-luminance
    ///    values) and `background: Canvas` (or no background), the
    ///    text is unreadable in light mode. Same for black on Canvas
    ///    in dark mode.
    ///
    /// Theme-aware values (`CanvasText`, `Canvas`, `currentColor`,
    /// `inherit`, `transparent`, `color-mix(...)` anchored to system
    /// colors) are treated as legible-by-construction and skipped.
    private static func checkTextContrast(html: String) -> [Issue] {
        var issues: [Issue] = []

        // (1) Inline style pairs on a single element.
        let inlineRegex = try? NSRegularExpression(
            pattern: #"\bstyle\s*=\s*["']([^"']+)["']"#,
            options: [.caseInsensitive]
        )
        if let regex = inlineRegex {
            let ns = html as NSString
            let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
            for match in matches where match.numberOfRanges >= 2 {
                let style = ns.substring(with: match.range(at: 1))
                if let issue = contrastIssueForStyleBlock(
                    style, selector: "inline style", location: "ui/index.html"
                ) {
                    issues.append(issue)
                }
            }
        }

        // (2 + 3 + 4) CSS rule blocks inside <style> tags. Resolve the
        // "page-level" color/background from body / html / :root first,
        // then use it as the implied cascade ancestor when a descendant
        // rule declares just one side of the pair.
        let rules = extractCSSRules(from: html)
        let pageLevel = resolvePageLevelColors(rules: rules)

        for ruleBlock in rules {
            if let issue = contrastIssueForStyleBlock(
                ruleBlock.declarations,
                selector: ruleBlock.selector,
                location: "ui/index.html"
            ) {
                issues.append(issue)
            }
            // (3) Cascaded pair check. Skip body/html/:root rules — they
            // supply the cascade base and would otherwise self-check
            // against their own declarations.
            if !isPageLevelSelector(ruleBlock.selector),
               let issue = cascadedContrastIssueForRule(
                ruleBlock,
                pageLevel: pageLevel,
                location: "ui/index.html"
               ) {
                issues.append(issue)
            }
            // (4) Body-level theme-breaking: hard-coded color against
            // `background: Canvas` (or no background) means the text is
            // illegible in one of the two system color schemes.
            if ruleBlock.selector.lowercased().contains("body") {
                if let issue = themeMismatchIssueForBody(ruleBlock.declarations) {
                    issues.append(issue)
                }
            }
        }

        return issues
    }

    /// Effective "body / page" color + background as resolved from
    /// `body`, `html`, or `:root` rules, used as the cascade base for
    /// descendant rules that only declare one side of the color/background
    /// pair.
    private struct PageLevelColors {
        /// Raw CSS value string for the base foreground (e.g. "white",
        /// "#fff", "rgb(...)"), nil if no page-level rule declares one.
        let colorRaw: String?
        /// Raw CSS value string for the base background.
        let backgroundRaw: String?
    }

    private static func resolvePageLevelColors(rules: [CSSRule]) -> PageLevelColors {
        var color: String?
        var bg: String?
        for rule in rules where isPageLevelSelector(rule.selector) {
            let decls = parseDeclarations(rule.declarations)
            if color == nil, let c = decls["color"] { color = c }
            if bg == nil,
               let b = decls["background-color"] ?? decls["background"] {
                bg = b
            }
        }
        return PageLevelColors(colorRaw: color, backgroundRaw: bg)
    }

    private static func isPageLevelSelector(_ selector: String) -> Bool {
        let norm = selector
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        // Match exact body/html/:root or the very common combinations
        // like "html, body" or ":root, body". Anything more elaborate
        // (a compound selector like `body.dark`) intentionally falls
        // through so we don't misread it as the cascade base.
        let tokens = norm
            .split(whereSeparator: { $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return tokens.allSatisfy { $0 == "body" || $0 == "html" || $0 == ":root" }
    }

    /// Pair a descendant rule's color (or background) with the page-
    /// level base of the opposite side and contrast-check. Returns nil
    /// when the rule already declares both (the in-block pair check
    /// handles it), when the pair can't be resolved to RGB, when
    /// either side is theme-aware, or when contrast is above the
    /// threshold.
    private static func cascadedContrastIssueForRule(
        _ rule: CSSRule,
        pageLevel: PageLevelColors,
        location: String
    ) -> Issue? {
        let decls = parseDeclarations(rule.declarations)
        let ownColor = decls["color"]
        let ownBG = decls["background-color"] ?? decls["background"]

        // In-block pair already handled by contrastIssueForStyleBlock.
        if ownColor != nil && ownBG != nil { return nil }

        let effectiveColor: String?
        let effectiveBG: String?
        let missing: String  // what's cascading from the page level
        if let c = ownColor, ownBG == nil {
            effectiveColor = c
            effectiveBG = pageLevel.backgroundRaw
            missing = "background (inherited from body)"
        } else if let b = ownBG, ownColor == nil {
            effectiveColor = pageLevel.colorRaw
            effectiveBG = b
            missing = "color (inherited from body)"
        } else {
            return nil  // rule declares neither
        }

        guard let fgStr = effectiveColor, let bgStr = effectiveBG else { return nil }
        guard !isThemeAwareColor(fgStr), !isThemeAwareColor(bgStr) else { return nil }
        guard let fg = parseColor(fgStr), let bg = parseColor(bgStr) else { return nil }
        let ratio = contrastRatio(fg, bg)
        guard ratio < 3.0 else { return nil }
        return Issue(
            severity: .warn,
            check: "text_contrast_low",
            file: location,
            message: String(
                format: "Low text contrast on %@: color %@ on %@ (%@) has a contrast ratio of %.2f (WCAG AA large-text threshold is 3.0).",
                rule.selector.trimmingCharacters(in: .whitespacesAndNewlines),
                fgStr.trimmingCharacters(in: .whitespaces),
                bgStr.trimmingCharacters(in: .whitespaces),
                missing, ratio
            ),
            suggestion: "Either give this rule its own background/color that pairs well, or bump the body-level \(missing.contains("background") ? "background" : "color") to contrast with descendant text."
        )
    }

    /// If the given CSS declaration block defines both a text color and a
    /// background color and their contrast ratio is below the threshold,
    /// return a warning; otherwise nil.
    private static func contrastIssueForStyleBlock(
        _ declarations: String,
        selector: String,
        location: String
    ) -> Issue? {
        let decls = parseDeclarations(declarations)
        guard let colorStr = decls["color"] ?? decls["Color"] else { return nil }
        let bgStr = decls["background-color"]
            ?? decls["background"]
            ?? decls["Background"]
            ?? decls["Background-color"]
        guard let bg = bgStr else { return nil }
        guard let fgRGB = parseColor(colorStr),
              let bgRGB = parseColor(bg) else { return nil }
        let ratio = contrastRatio(fgRGB, bgRGB)
        // 3.0 is the WCAG AA threshold for large text. We pick it over
        // the stricter 4.5 to leave authors room for deliberate stylistic
        // choices (faded subheaders, etc.) and flag only the genuinely
        // unreadable cases.
        guard ratio < 3.0 else { return nil }
        return Issue(
            severity: .warn,
            check: "text_contrast_low",
            file: location,
            message: String(
                format: "Low text contrast on %@: color %@ on background %@ has a contrast ratio of %.2f (WCAG AA large-text threshold is 3.0).",
                selector, colorStr.trimmingCharacters(in: .whitespaces),
                bg.trimmingCharacters(in: .whitespaces), ratio
            ),
            suggestion: "Prefer `color: CanvasText` and `background: Canvas` (theme-aware). If you must hard-code, pick a dark text on a light background or vice versa."
        )
    }

    /// Flag body rules that set `color: white|#fff|…` or `color: black|#000|…`
    /// alongside `background: Canvas` (or no explicit background) — the
    /// hard-coded color is unreadable in one of the two system color
    /// schemes.
    private static func themeMismatchIssueForBody(_ declarations: String) -> Issue? {
        let decls = parseDeclarations(declarations)
        guard let colorStr = decls["color"] else { return nil }
        let bgRaw = decls["background"] ?? decls["background-color"]
        let bgIsThemeAware = bgRaw == nil || isThemeAwareColor(bgRaw ?? "")
        guard bgIsThemeAware else { return nil }  // handled by the pair check
        guard let fg = parseColor(colorStr) else { return nil }
        let lum = luminance(fg)
        // Extreme colors (near-white / near-black) clash with the
        // opposite theme. 0.8+ is effectively white, <0.1 is black.
        let problem: String?
        if lum > 0.8 {
            problem = "light"
        } else if lum < 0.1 {
            problem = "dark"
        } else {
            problem = nil
        }
        guard let mode = problem else { return nil }
        return Issue(
            severity: .warn,
            check: "theme_breaking_body_color",
            file: "ui/index.html",
            message: "body has hard-coded \(mode) `color: \(colorStr.trimmingCharacters(in: .whitespaces))` against a theme-aware background — text will be unreadable in \(mode == "light" ? "light" : "dark") mode.",
            suggestion: "Use `color: CanvasText` so the text color follows the host's light/dark mode. If you need a specific palette, set an explicit theme-matching background color too."
        )
    }

    /// Body declares a hard-coded near-black or near-white background but
    /// the document doesn't declare a matching `color-scheme`. cdp-ui's
    /// theme tokens (`--cdp-fg`, `--cdp-muted`, `--cdp-track-bg`) all
    /// resolve through `CanvasText` / `Canvas`, whose values are picked
    /// from the user-agent's color-scheme — without a declaration, WebKit
    /// defaults to light. So a dark page paints cdp-ui text in black:
    /// invisible against the author's hard-coded dark background.
    ///
    /// Live AU dodges this because the host process's NSAppearance
    /// propagates into WebKit; the trap is for exported AUs and preview
    /// pages, where the color-scheme has to be declared explicitly.
    private static func checkColorSchemeDeclared(html: String) -> [Issue] {
        let rules = extractCSSRules(from: html)

        // Walk page-level rules to find the effective background. First
        // declaration wins (mirrors cascade approximately for what's
        // typically a one-rule body declaration).
        var bgRaw: String?
        for rule in rules where isPageLevelSelector(rule.selector) {
            let decls = parseDeclarations(rule.declarations)
            if let b = decls["background-color"] ?? decls["background"] {
                bgRaw = b
                break
            }
        }
        guard let bg = bgRaw else { return [] }

        // Theme-aware backgrounds (Canvas, transparent, ...) are fine —
        // they already follow the system color-scheme.
        if isThemeAwareColor(bg) { return [] }

        // Resolve to luminance. Mid-greys aren't a theme-direction
        // signal; only flag the unambiguous extremes.
        guard let rgb = parseColor(bg) else { return [] }
        let lum = luminance(rgb)
        let needs: String
        if lum < 0.2 {
            needs = "dark"
        } else if lum > 0.8 {
            needs = "light"
        } else {
            return []
        }

        // Tokenize a `color-scheme` value into its keyword set so we
        // accept `light dark`/`only dark` but don't false-negative on
        // unrelated identifiers that happen to contain `light` or
        // `dark` as a substring (e.g. a stray `highlight`).
        func colorSchemeAccepts(_ value: String) -> Bool {
            let tokens = Set(value.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init))
            if tokens.contains(needs) { return true }
            if tokens.contains("light") && tokens.contains("dark") { return true }
            return false
        }

        // Match against `color-scheme` in any rule (typically on :root,
        // but authors put it on html or body too — accept anywhere).
        for rule in rules {
            let decls = parseDeclarations(rule.declarations)
            if let cs = decls["color-scheme"], colorSchemeAccepts(cs) {
                return []
            }
        }

        // ...or as <meta name="color-scheme" content="...">. HTML
        // attribute order is insignificant, so match the whole tag and
        // pull `name` and `content` out independently — a regex that
        // pinned `name` before `content` would miss the equally-valid
        // `<meta content="dark" name="color-scheme">`.
        let tagPattern = #"<meta\b[^>]*>"#
        let attrPattern = #"(\w[\w-]*)\s*=\s*["']([^"']*)["']"#
        if let tagRegex = try? NSRegularExpression(pattern: tagPattern, options: [.caseInsensitive]),
           let attrRegex = try? NSRegularExpression(pattern: attrPattern, options: []) {
            let ns = html as NSString
            for tagMatch in tagRegex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                let tag = ns.substring(with: tagMatch.range)
                let tagNS = tag as NSString
                var attrs: [String: String] = [:]
                for am in attrRegex.matches(in: tag, range: NSRange(location: 0, length: tagNS.length)) where am.numberOfRanges >= 3 {
                    let key = tagNS.substring(with: am.range(at: 1)).lowercased()
                    let val = tagNS.substring(with: am.range(at: 2))
                    attrs[key] = val
                }
                guard attrs["name"]?.lowercased() == "color-scheme",
                      let content = attrs["content"] else { continue }
                if colorSchemeAccepts(content) { return [] }
            }
        }

        return [
            Issue(
                severity: .warn,
                check: "color_scheme_undeclared",
                file: "ui/index.html",
                message: String(
                    format: "body has a hard-coded %@ background (%@, luminance %.2f) but the document doesn't declare `color-scheme: %@` — CSS system colors (`Canvas`, `CanvasText`) used by cdp-ui will resolve to the wrong shade, making slotted labels and other theme-aware text illegible against your background.",
                    needs, bg.trimmingCharacters(in: .whitespaces), lum, needs
                ),
                suggestion: "Add `:root { color-scheme: \(needs); }` (or `<meta name=\"color-scheme\" content=\"\(needs)\">`) so cdp-ui's CanvasText-based tokens follow your background."
            )
        ]
    }

    // MARK: - CSS parsing helpers

    private struct CSSRule {
        let selector: String
        let declarations: String
    }

    /// Extract `selector { declarations }` blocks from the HTML's
    /// `<style>` tags. Pragmatic — not a real CSS parser; skips @-rules
    /// and nested blocks. Good enough for flat preset UIs.
    private static func extractCSSRules(from html: String) -> [CSSRule] {
        var rules: [CSSRule] = []
        // Extract <style>...</style> contents.
        let styleTagRegex = try? NSRegularExpression(
            pattern: #"<style[^>]*>([\s\S]*?)</style>"#,
            options: [.caseInsensitive]
        )
        guard let styleRegex = styleTagRegex else { return [] }
        let ns = html as NSString
        let styleMatches = styleRegex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        for match in styleMatches where match.numberOfRanges >= 2 {
            let styleContent = ns.substring(with: match.range(at: 1))
            // Strip @-blocks (e.g. @media, @supports) crudely to avoid
            // their selectors confusing the flat parser. We don't try
            // to recurse into them in this pass.
            let stripped = removeAtBlocks(styleContent)
            // Flat "selector { ... }" extraction.
            let ruleRegex = try? NSRegularExpression(
                pattern: #"([^{}]+)\{([^{}]*)\}"#,
                options: []
            )
            guard let rr = ruleRegex else { continue }
            let rns = stripped as NSString
            let ruleMatches = rr.matches(in: stripped, range: NSRange(location: 0, length: rns.length))
            for rm in ruleMatches where rm.numberOfRanges >= 3 {
                let selector = rns.substring(with: rm.range(at: 1))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let decls = rns.substring(with: rm.range(at: 2))
                guard !selector.isEmpty else { continue }
                rules.append(CSSRule(selector: selector, declarations: decls))
            }
        }
        return rules
    }

    /// Crudely remove `@rule { ... }` blocks from CSS. Balanced-brace
    /// scanning so nested rules inside a `@media` don't leak out.
    private static func removeAtBlocks(_ css: String) -> String {
        var out = ""
        var i = css.startIndex
        while i < css.endIndex {
            let c = css[i]
            if c == "@" {
                // Skip until matching closing brace.
                if let openIdx = css[i...].firstIndex(of: "{") {
                    var depth = 1
                    var j = css.index(after: openIdx)
                    while j < css.endIndex && depth > 0 {
                        if css[j] == "{" { depth += 1 }
                        else if css[j] == "}" { depth -= 1 }
                        j = css.index(after: j)
                    }
                    i = j
                    continue
                } else {
                    // Unterminated @-rule; bail.
                    break
                }
            }
            out.append(c)
            i = css.index(after: i)
        }
        return out
    }

    /// Parse a flat `key: value; key: value;` declaration block into a
    /// dictionary. Keys are lowercased; values retain case. Multiple
    /// assignments to the same key resolve to the last one (matches
    /// CSS cascade for a single rule block).
    private static func parseDeclarations(_ block: String) -> [String: String] {
        var out: [String: String] = [:]
        for rawDecl in block.split(separator: ";") {
            let parts = rawDecl.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            out[key] = value
        }
        return out
    }

    // MARK: - Color parsing + luminance

    /// Theme-aware or insensitive values we don't try to compute contrast
    /// for — they're either delegated to the OS (CanvasText/Canvas),
    /// inherit from context (currentColor/inherit), or mean "no paint"
    /// (transparent). Returning `true` means: skip the contrast check;
    /// it's the author's deliberate theme-handling.
    private static func isThemeAwareColor(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("color-mix(") { return true }
        let themeAwareKeywords: Set<String> = [
            "canvastext", "canvas", "currentcolor", "inherit",
            "transparent", "initial", "unset", "revert", "revert-layer",
            "accentcolor", "accentcolortext", "buttontext", "buttonface",
            "linktext", "visitedtext", "field", "fieldtext",
            "highlighttext", "highlight", "graytext", "markertext",
        ]
        return themeAwareKeywords.contains(trimmed)
    }

    /// Parse a CSS color value into sRGB (0..1) components. Supports
    /// hex `#rgb`/`#rrggbb`/`#rgba`/`#rrggbbaa`, `rgb(r, g, b)`,
    /// `rgba(r, g, b, a)`, and a handful of common named colors.
    /// Returns nil for theme-aware values (callers should check
    /// `isThemeAwareColor` first to decide whether to treat nil as a
    /// skip vs. an error).
    private static func parseColor(_ raw: String) -> (r: Double, g: Double, b: Double)? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if isThemeAwareColor(value) { return nil }

        // Hex.
        if value.hasPrefix("#") {
            let hex = String(value.dropFirst())
            let expanded: String
            switch hex.count {
            case 3:
                expanded = hex.map { "\($0)\($0)" }.joined()
            case 4:
                // #rgba -> #rrggbb (ignore alpha for contrast)
                let trimmed = String(hex.prefix(3))
                expanded = trimmed.map { "\($0)\($0)" }.joined()
            case 6:
                expanded = hex
            case 8:
                expanded = String(hex.prefix(6))
            default:
                return nil
            }
            guard expanded.count == 6,
                  let r = Int(expanded.prefix(2), radix: 16),
                  let g = Int(expanded.dropFirst(2).prefix(2), radix: 16),
                  let b = Int(expanded.dropFirst(4).prefix(2), radix: 16)
            else { return nil }
            return (Double(r) / 255, Double(g) / 255, Double(b) / 255)
        }

        // rgb(...) / rgba(...)
        if value.hasPrefix("rgb(") || value.hasPrefix("rgba(") {
            let inside = value
                .replacingOccurrences(of: "rgba(", with: "")
                .replacingOccurrences(of: "rgb(", with: "")
                .replacingOccurrences(of: ")", with: "")
            let parts = inside.split(whereSeparator: { ",/ ".contains($0) })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard parts.count >= 3 else { return nil }
            func channel(_ s: String) -> Double? {
                if s.hasSuffix("%") {
                    guard let pct = Double(s.dropLast()) else { return nil }
                    return max(0, min(1, pct / 100))
                }
                guard let n = Double(s) else { return nil }
                return max(0, min(1, n / 255))
            }
            guard let r = channel(parts[0]),
                  let g = channel(parts[1]),
                  let b = channel(parts[2]) else { return nil }
            return (r, g, b)
        }

        // hsl(...)/hsla(...) — parse by converting HSL to RGB.
        if value.hasPrefix("hsl(") || value.hasPrefix("hsla(") {
            let inside = value
                .replacingOccurrences(of: "hsla(", with: "")
                .replacingOccurrences(of: "hsl(", with: "")
                .replacingOccurrences(of: ")", with: "")
            let parts = inside.split(whereSeparator: { ",/ ".contains($0) })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard parts.count >= 3 else { return nil }
            guard let h = Double(parts[0].replacingOccurrences(of: "deg", with: "")),
                  let s = Double(parts[1].replacingOccurrences(of: "%", with: "")),
                  let l = Double(parts[2].replacingOccurrences(of: "%", with: "")) else { return nil }
            return hslToRGB(h: h, s: s / 100, l: l / 100)
        }

        // Named colors (small table — we only care about the ones
        // preset authors reach for).
        return namedColorTable[value]
    }

    /// Luminance per WCAG 2.1 relative-luminance formula.
    private static func luminance(_ c: (r: Double, g: Double, b: Double)) -> Double {
        func lin(_ x: Double) -> Double {
            x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    /// WCAG 2.1 contrast ratio. Output range [1, 21]; 1 = identical,
    /// 21 = pure white on pure black.
    private static func contrastRatio(
        _ a: (r: Double, g: Double, b: Double),
        _ b: (r: Double, g: Double, b: Double)
    ) -> Double {
        let la = luminance(a), lb = luminance(b)
        let (hi, lo) = la > lb ? (la, lb) : (lb, la)
        return (hi + 0.05) / (lo + 0.05)
    }

    private static func hslToRGB(h: Double, s: Double, l: Double) -> (r: Double, g: Double, b: Double) {
        let c = (1 - abs(2 * l - 1)) * s
        let hp = (h.truncatingRemainder(dividingBy: 360)) / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        var (r, g, b): (Double, Double, Double) = (0, 0, 0)
        switch hp {
        case 0..<1: (r, g, b) = (c, x, 0)
        case 1..<2: (r, g, b) = (x, c, 0)
        case 2..<3: (r, g, b) = (0, c, x)
        case 3..<4: (r, g, b) = (0, x, c)
        case 4..<5: (r, g, b) = (x, 0, c)
        case 5..<6: (r, g, b) = (c, 0, x)
        default: break
        }
        let m = l - c / 2
        return (r + m, g + m, b + m)
    }

    /// The small set of CSS named colors preset authors actually use.
    /// Skipping the full X11 palette intentionally — not worth the
    /// surface area. If a preset uses an obscure named color we miss,
    /// the contrast check silently skips it; the worst case is a
    /// missed warning, not a false positive.
    private static let namedColorTable: [String: (r: Double, g: Double, b: Double)] = [
        "white":     (1, 1, 1),
        "black":     (0, 0, 0),
        "red":       (1, 0, 0),
        "green":     (0, 0.5, 0),
        "lime":      (0, 1, 0),
        "blue":      (0, 0, 1),
        "yellow":    (1, 1, 0),
        "cyan":      (0, 1, 1),
        "magenta":   (1, 0, 1),
        "gray":      (0.5, 0.5, 0.5),
        "grey":      (0.5, 0.5, 0.5),
        "lightgray": (0.827, 0.827, 0.827),
        "lightgrey": (0.827, 0.827, 0.827),
        "darkgray":  (0.663, 0.663, 0.663),
        "darkgrey":  (0.663, 0.663, 0.663),
        "silver":    (0.753, 0.753, 0.753),
        "gold":      (1, 0.843, 0),
        "orange":    (1, 0.647, 0),
        "pink":      (1, 0.753, 0.796),
        "purple":    (0.502, 0, 0.502),
        "brown":     (0.647, 0.165, 0.165),
    ]

    // MARK: - Helpers

    /// Strip `<!-- ... -->` comments from HTML before content scans that
    /// shouldn't see commented-out example markup (e.g. the starter
    /// scaffold's "<cdp-toggle param=\"Bypass\">" example block).
    /// Non-greedy match across newlines.
    private static func stripHTMLComments(_ html: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "<!--[\\s\\S]*?-->",
            options: []
        ) else { return html }
        let ns = html as NSString
        return regex.stringByReplacingMatches(
            in: html,
            range: NSRange(location: 0, length: ns.length),
            withTemplate: ""
        )
    }

    /// Every `ConjureDSP.state.{get,set,onChange,onAnyChange}('K', ...)`
    /// reference in the UI must resolve to a key declared in the script's
    /// `STATE` block (Python) / `state_struct!` block (Rust). The bundle
    /// STATE channel is bundle-private and not part of the AU parameter
    /// tree, so a typo here silently fails — `set` is a no-op, `get`
    /// returns the default, `onChange` never fires.
    ///
    /// Dynamic-key references (non-literal first arg, e.g.
    /// `state.set(myVar, ...)`) are silently skipped — they can't be
    /// statically resolved. Same for cases where we can't parse the
    /// script (we emit a `warn` so the author isn't blocked, but each
    /// individual key reference is otherwise allowed through).
    ///
    /// TODO: STATE-defaults-over-cap warning. Need to compare the literal
    /// `STATE = {...}` / `state_struct!` defaults against a declared
    /// `STATE_MAX_BYTES = N` / `state!(T, max_bytes = N)`. Both are
    /// heuristic and the runtime smoke test catches this anyway when the
    /// kernel rejects on apply, so leaving as a follow-up.
    private static func checkStateReferences(html: String, bundle: PresetBundle) -> [Issue] {
        // Pull every literal-key `state.<api>('KEY', ...)` reference out
        // of the UI HTML / inline JS. Multi-quote-style support so we
        // pick up both single- and double-quoted, plus backticks (people
        // template-literal these for "no real reason" all the time).
        let refRegex = try? NSRegularExpression(
            pattern: #"ConjureDSP\.state\.(?:get|set|onChange|onAnyChange)\s*\(\s*(['"`])([^'"`]+)\1"#,
            options: []
        )
        guard let regex = refRegex else { return [] }

        let scanned = stripHTMLComments(html)
        let ns = scanned as NSString
        let matches = regex.matches(in: scanned, range: NSRange(location: 0, length: ns.length))

        // No literal references — nothing to validate.
        if matches.isEmpty { return [] }

        // Try to parse declared STATE keys from the bundle's script
        // source. Imperfect (regex over Python / Rust source, not a
        // real parser) so a parse failure falls back to a warn instead
        // of blocking the author.
        let scriptKeysOpt = declaredStateKeys(forBundle: bundle)

        var issues: [Issue] = []
        guard let declared = scriptKeysOpt else {
            issues.append(
                Issue(
                    severity: .warn,
                    check: "state_keys_unparseable",
                    file: "ui/index.html",
                    message: "UI references ConjureDSP.state.* but the validator could not parse STATE keys from the script for verification.",
                    suggestion: "If the keys are correct at runtime you can ignore this; otherwise simplify the STATE declaration so the static lint can read it (top-level `STATE = {\"key\": default, ...}` for Python). Rust scripts use `state!()` and parse raw bytes themselves, so the validator can't introspect declared keys — runtime behavior is the source of truth."
                )
            )
            return issues
        }

        let declaredNorms = Set(declared.map { looseNormalize($0) })
        let declaredDecls = declared.map { name in
            PresetManifest.ParamDecl(
                name: name, key: nil, min: 0, max: 0, default: 0,
                unit: nil, curve: nil, style: nil, options: nil
            )
        }

        var seenUnresolved: Set<String> = []
        for match in matches where match.numberOfRanges >= 3 {
            let value = ns.substring(with: match.range(at: 2))
            if declaredNorms.contains(looseNormalize(value)) { continue }
            if seenUnresolved.contains(value) { continue }
            seenUnresolved.insert(value)
            let nearest = nearestDeclaredName(to: value, declared: declaredDecls)
            issues.append(
                Issue(
                    severity: .fail,
                    check: "state_key_referenced_in_ui",
                    file: "ui/index.html",
                    message: "ConjureDSP.state reference uses key \"\(value)\" but the script declares no such STATE key.",
                    suggestion: nearest.map { "Did you mean \"\($0)\"?" } ?? "Add \"\(value)\" to the script's STATE declaration, or update the UI to use an existing key."
                )
            )
        }
        return issues
    }

    /// Best-effort extraction of declared STATE keys from the bundle's
    /// entry script. Returns nil when we can't parse (caller decides
    /// whether to warn or proceed).
    ///
    /// Python: scan for top-level `STATE = {...}` and pull string keys
    /// out of the literal dict. Won't catch dynamically-built dicts.
    /// Rust: scan for `state_struct! { pub struct <Name> { ... } }` and
    /// pull field names out of the struct body. Won't catch types
    /// declared outside the macro.
    private static func declaredStateKeys(forBundle bundle: PresetBundle) -> [String]? {
        guard let source = try? String(contentsOf: bundle.entryScriptURL, encoding: .utf8) else {
            return nil
        }
        let ext = bundle.entryScriptURL.pathExtension.lowercased()
        switch ext {
        case "py":
            return parsePythonStateKeys(source: source)
        case "rs":
            return parseRustStateKeys(source: source)
        default:
            return nil
        }
    }

    private static func parsePythonStateKeys(source: String) -> [String]? {
        guard let startRegex = try? NSRegularExpression(
            pattern: #"(?m)^\s*STATE\s*(?::[^=]+)?=\s*\{"#,
            options: []
        ) else { return nil }
        let ns = source as NSString
        guard let match = startRegex.firstMatch(
            in: source, range: NSRange(location: 0, length: ns.length)
        ) else { return nil }
        let openIdx = match.range.location + match.range.length - 1  // points at `{`

        var keys: [String] = []
        var depth = 1
        var i = openIdx + 1
        var awaitingKey = true

        while i < ns.length && depth > 0 {
            let ch = ns.character(at: i)

            // Skip line comments through end of line.
            if ch == 0x23 /* # */ {
                while i < ns.length && ns.character(at: i) != 0x0A { i += 1 }
                continue
            }

            // Quoted string: capture as a key only if we're at top-level
            // and awaiting one. Otherwise just skip past it (handles
            // string values, including ones containing `{`/`}`/`[`/`]`).
            if ch == 0x22 /* " */ || ch == 0x27 /* ' */ {
                let quote = ch
                let strStart = i + 1
                var j = strStart
                while j < ns.length {
                    let c = ns.character(at: j)
                    if c == 0x5C /* \ */ { j += 2; continue }
                    if c == quote { break }
                    j += 1
                }
                if depth == 1 && awaitingKey {
                    let raw = ns.substring(with: NSRange(location: strStart, length: j - strStart))
                    var k = j + 1
                    while k < ns.length {
                        let c = ns.character(at: k)
                        if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { k += 1; continue }
                        break
                    }
                    if k < ns.length && ns.character(at: k) == 0x3A /* : */ {
                        keys.append(raw)
                        awaitingKey = false
                        i = k + 1
                        continue
                    }
                }
                i = j + 1
                continue
            }

            switch ch {
            case 0x7B /* { */, 0x5B /* [ */, 0x28 /* ( */:
                depth += 1
            case 0x7D /* } */, 0x5D /* ] */, 0x29 /* ) */:
                depth -= 1
            case 0x2C /* , */:
                if depth == 1 { awaitingKey = true }
            default:
                break
            }
            i += 1
        }
        guard depth == 0 else { return nil }
        return keys
    }

    private static func parseRustStateKeys(source: String) -> [String]? {
        _ = source
        return nil
    }

    /// Every `<cdp-scope telemetry="X">` reference must resolve to a slot
    /// declared in `manifest.telemetry` — when the manifest has a
    /// `telemetry` block at all. When the block is absent we skip the
    /// check entirely: unlike `param=` (which the bridge resolves at
    /// `_init` against manifest metadata, before the DSP loads), the
    /// telemetry binding happens at frame-arrival time against whatever
    /// the loaded script actually publishes — no static guarantee broken.
    /// Authors who want pre-load lint just declare a `telemetry` array
    /// in their manifest.
    private static func checkTelemetryReferences(html: String, bundle: PresetBundle) -> [Issue] {
        let declared = bundle.manifest.telemetry ?? []
        guard !declared.isEmpty else { return [] }

        guard let regex = try? NSRegularExpression(
            pattern: #"<cdp-scope\b[^>]*\btelemetry\s*=\s*["']([^"']+)["']"#,
            options: [.caseInsensitive]
        ) else { return [] }

        let scanned = stripHTMLComments(html)
        let ns = scanned as NSString
        let matches = regex.matches(in: scanned, range: NSRange(location: 0, length: ns.length))

        let declaredNorms = Set(declared.map { looseNormalize($0.name) })
        var issues: [Issue] = []
        var seenUnresolved: Set<String> = []
        for match in matches where match.numberOfRanges >= 2 {
            let value = ns.substring(with: match.range(at: 1))
            if declaredNorms.contains(looseNormalize(value)) { continue }
            if seenUnresolved.contains(value) { continue }
            seenUnresolved.insert(value)
            let nearest = nearestDeclaredTelemetry(to: value, declared: declared)
            issues.append(
                Issue(
                    severity: .fail,
                    check: "telemetry_referenced_in_ui",
                    file: "ui/index.html",
                    message: "telemetry=\"\(value)\" doesn't match any manifest.telemetry[].name.",
                    suggestion: nearest.map { "Did you mean \"\($0)\"?" } ?? "Add the slot to manifest.telemetry, or bind to an existing name."
                )
            )
        }
        return issues
    }

    private static func nearestDeclaredTelemetry(
        to query: String,
        declared: [PresetManifest.TelemetryDecl]
    ) -> String? {
        let qn = looseNormalize(query)
        var best: (name: String, dist: Int)?
        for t in declared {
            let d = levenshtein(qn, looseNormalize(t.name))
            if best == nil || d < best!.dist {
                best = (t.name, d)
            }
        }
        guard let winner = best, winner.dist <= max(2, query.count / 3) else { return nil }
        return winner.name
    }

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
