import Foundation

/// A named DSP script preset — either bundled with the plugin (factory) or saved by the user.
struct Preset: Identifiable, Hashable {
    enum Source: Hashable {
        case factory(resourceName: String)
        case user(url: URL)
    }

    /// Unique key: "factory:Passthrough" or "user:My Filter"
    let id: String
    let name: String
    let source: Source
    /// Non-nil only for factory presets, for AUAudioUnitPreset interop with DAW menus.
    let factoryPresetNumber: Int?

    var isFactory: Bool {
        if case .factory = source { return true }
        return false
    }
}

/// Single source of truth for factory preset metadata, used by both PresetManager and the AU.
enum FactoryPresetRegistry {
    struct Entry {
        let name: String
        let number: Int
        let resourceName: String
    }

    static let entries: [Entry] = [
        Entry(name: "Passthrough", number: 0, resourceName: "preset_passthrough"),
        Entry(name: "Tremolo", number: 1, resourceName: "preset_tremolo"),
        Entry(name: "Bitcrush", number: 2, resourceName: "preset_bitcrush"),
    ]
}
