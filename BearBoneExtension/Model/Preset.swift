import Foundation

/// A named DSP script preset — either bundled with the plugin (factory) or saved by the user.
struct Preset: Identifiable, Hashable {
    enum Source: Hashable {
        case factory(resourceName: String)
        case user(url: URL)
    }

    /// Unique key: "factory:Passthrough" or "user:My Filter.py"
    let id: String
    let name: String
    let source: Source
    /// Non-nil only for factory presets, for AUAudioUnitPreset interop with DAW menus.
    let factoryPresetNumber: Int?
    let language: ScriptLanguage

    var isFactory: Bool {
        if case .factory = source { return true }
        return false
    }

    /// File extension for this preset's language.
    var fileExtension: String {
        language == .rust ? "rs" : "py"
    }
}

/// Single source of truth for factory preset metadata, used by both PresetManager and the AU.
enum FactoryPresetRegistry {
    struct Entry {
        let name: String
        let number: Int
        let resourceName: String
        let language: ScriptLanguage
    }

    static let entries: [Entry] = [
        Entry(name: "Passthrough (Python)", number: 0, resourceName: "preset_passthrough", language: .python),
        Entry(name: "Tremolo (Python)", number: 1, resourceName: "preset_tremolo", language: .python),
        Entry(name: "Bitcrush (Python)", number: 2, resourceName: "preset_bitcrush", language: .python),
        Entry(name: "Passthrough (Rust)", number: 3, resourceName: "preset_passthrough_rust", language: .rust),
    ]
}
