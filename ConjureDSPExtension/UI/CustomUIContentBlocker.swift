import Foundation
import os.log
import WebKit

private let log = Logger(
    subsystem: "com.MichaelJancsy.ConjureDSP.ConjureDSPExtension",
    category: "CustomUIContentBlocker"
)

/// WebKit content-rule-list that blocks all network traffic from custom-UI
/// webviews except the allowed local schemes.
///
/// Why this exists: custom UIs run attacker-controlled JS when users pull
/// preset bundles from third-party GitHub repos. We ship a CSP header via
/// `BundleAssetSchemeHandler`, but CSP is advisory — an author `<meta>`
/// tag can relax it, and enforcement varies across fetch methods and
/// WebKit versions. `WKContentRuleList` is a second, non-bypassable layer
/// enforced by WebKit itself and impossible for page JS to disable.
///
/// Policy: block everything, then re-allow the local schemes we actually
/// use:
///   - `conjuredsp-preset://` — the custom scheme that serves bundle
///     assets through `BundleAssetSchemeHandler`.
///   - `data:` — inline base64 images/fonts in authored HTML.
///   - `blob:` — blobs generated locally by JS (e.g. dynamic chart
///     canvases). No egress path, safe to allow.
///
/// `http://`, `https://`, `ws://`, `wss://`, `file://`, and everything
/// else is dropped regardless of what author JS or author meta tags do.
enum CustomUIContentBlocker {
    /// Identifier used with `WKContentRuleListStore`. The store caches
    /// compiled rule lists on disk keyed by this string, so subsequent
    /// launches skip the compile step. Bump the version suffix when the
    /// rule set changes meaningfully so old cached rules get invalidated.
    static let identifier = "conjuredsp-custom-ui-v1"

    /// The rule list as a JSON string. WebKit parses this on
    /// `compileContentRuleList(...)`.
    ///
    /// The first rule blocks everything. Subsequent rules use
    /// `ignore-previous-rules` to punch holes for the local schemes we
    /// accept. Order matters: WebKit evaluates rules top-to-bottom and
    /// applies `ignore-previous-rules` to invalidate earlier matches.
    static let rulesJSON: String = """
    [
      { "trigger": { "url-filter": ".*" },
        "action":  { "type": "block" } },
      { "trigger": { "url-filter": "^conjuredsp-preset://.*" },
        "action":  { "type": "ignore-previous-rules" } },
      { "trigger": { "url-filter": "^data:.*" },
        "action":  { "type": "ignore-previous-rules" } },
      { "trigger": { "url-filter": "^blob:.*" },
        "action":  { "type": "ignore-previous-rules" } }
    ]
    """

    /// Compile (or re-use a cached compile of) the rule list and attach
    /// it to the given configuration's content controller. Fire and
    /// forget — if compilation fails we log and leave the configuration
    /// with only the CSP header for protection.
    ///
    /// Call site is typically inside `makeNSView`. The initial
    /// `webView.load(...)` request targets the custom scheme (allowed),
    /// so late arrival of the compiled rules doesn't race the first
    /// page load. Rules gate subsequent fetch/XHR/navigation attempts,
    /// which always happen after `makeNSView` has returned.
    static func apply(to configuration: WKWebViewConfiguration) {
        guard let store = WKContentRuleListStore.default() else {
            log.error("WKContentRuleListStore.default() returned nil — skipping network block")
            return
        }
        // `lookUpContentRuleList` returns the cached compiled list if
        // one exists. Only fall back to `compileContentRuleList` on a
        // cold cache to skip the ~10ms parse on every launch.
        store.lookUpContentRuleList(forIdentifier: identifier) { cached, _ in
            if let cached {
                configuration.userContentController.add(cached)
                return
            }
            store.compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: rulesJSON
            ) { list, error in
                if let list {
                    configuration.userContentController.add(list)
                } else if let error {
                    log.error("Content rule compile failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}
