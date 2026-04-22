import Combine
import Foundation

/// Per-bundle "show the custom UI?" preference, persisted in UserDefaults.
///
/// A bundle may ship a custom HTML/JS UI; by default the plugin renders it
/// whenever `bundle.hasCustomUI` is true. Users sometimes want to fall back
/// to the stock slider panel — to compare, to get a quick numeric view, or
/// simply because they prefer sliders for a given preset. This object
/// stores that opt-out, keyed by the bundle's stable name (matches the
/// `Preset.id` discriminator), so the choice survives plugin reload and
/// follows the preset across sessions.
///
/// `showCustomUI` is @Published so views can bind `.toggle` style controls
/// directly and react without separate `@State` mirrors.
@MainActor
final class CustomUIPreference: ObservableObject {
    /// UserDefaults key prefix. Leaf key is the bundle's sanitized name.
    /// Value is `Bool`: `true` → render custom UI (default), `false` →
    /// force stock sliders.
    private static let keyPrefix = "conjuredsp.customUI.showCustomUI."

    /// The bundle whose preference we're reading/writing. Setting this
    /// updates `showCustomUI` from storage; clearing it (nil) leaves
    /// showCustomUI at the default so non-bundle presets don't flip the
    /// toggle state.
    var bundleKey: String? {
        didSet {
            guard bundleKey != oldValue else { return }
            showCustomUI = Self.read(key: bundleKey)
        }
    }

    /// The effective preference for the active bundle. Writing persists
    /// immediately.
    @Published var showCustomUI: Bool = true {
        didSet {
            guard let key = bundleKey, oldValue != showCustomUI else { return }
            Self.write(key: key, value: showCustomUI)
        }
    }

    init(bundleKey: String? = nil) {
        self.bundleKey = bundleKey
        self.showCustomUI = Self.read(key: bundleKey)
    }

    private static func storageKey(_ bundleKey: String?) -> String? {
        guard let bundleKey, !bundleKey.isEmpty else { return nil }
        return keyPrefix + bundleKey
    }

    private static func read(key: String?) -> Bool {
        guard let storageKey = storageKey(key) else { return true }
        // Default true — if no explicit preference is stored, custom UIs
        // render. UserDefaults.bool returns false for missing keys, so
        // we have to go through `object(forKey:)` to distinguish.
        guard UserDefaults.standard.object(forKey: storageKey) != nil else {
            return true
        }
        return UserDefaults.standard.bool(forKey: storageKey)
    }

    private static func write(key: String, value: Bool) {
        guard let storageKey = storageKey(key) else { return }
        UserDefaults.standard.set(value, forKey: storageKey)
    }
}
