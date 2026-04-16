import Foundation
import os.log
import WebKit

private let log = Logger(
    subsystem: "com.MichaelJancsy.ConjureDSP.ExportAU",
    category: "CustomUIContentBlocker"
)

/// Mirror of the main extension's content blocker — keeps the rule set and
/// allowed-scheme list identical so exported AUs get the same network
/// egress protection as the in-plugin custom-UI renderer.
///
/// Kept as a direct copy (not a shared source) because the export
/// template is its own Xcode project with its own subsystem string; the
/// only functional difference between the two files is the Logger
/// subsystem. Changes to the rule set must be applied in both places.
enum CustomUIContentBlocker {
    static let identifier = "conjuredsp-custom-ui-v1"

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

    static func apply(to configuration: WKWebViewConfiguration) {
        guard let store = WKContentRuleListStore.default() else {
            log.error("WKContentRuleListStore.default() returned nil — skipping network block")
            return
        }
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
