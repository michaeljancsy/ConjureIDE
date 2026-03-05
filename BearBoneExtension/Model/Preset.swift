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
        // Utility
        Entry(name: "Passthrough (Python)", number: 0, resourceName: "preset_passthrough", language: .python),
        Entry(name: "Passthrough (Rust)", number: 1, resourceName: "preset_passthrough_rust", language: .rust),
        Entry(name: "Gain + Pan (Python)", number: 2, resourceName: "preset_gainpan", language: .python),
        Entry(name: "Gain + Pan (Rust)", number: 3, resourceName: "preset_gainpan_rust", language: .rust),
        Entry(name: "DC Blocker (Python)", number: 4, resourceName: "preset_dcblocker", language: .python),
        Entry(name: "DC Blocker (Rust)", number: 5, resourceName: "preset_dcblocker_rust", language: .rust),
        Entry(name: "Stereo Width (Python)", number: 6, resourceName: "preset_stereowidth", language: .python),
        Entry(name: "Stereo Width (Rust)", number: 7, resourceName: "preset_stereowidth_rust", language: .rust),

        // Distortion / Saturation
        Entry(name: "Soft Clip (Python)", number: 8, resourceName: "preset_softclip", language: .python),
        Entry(name: "Soft Clip (Rust)", number: 9, resourceName: "preset_softclip_rust", language: .rust),
        Entry(name: "Hard Clip (Python)", number: 10, resourceName: "preset_hardclip", language: .python),
        Entry(name: "Hard Clip (Rust)", number: 11, resourceName: "preset_hardclip_rust", language: .rust),
        Entry(name: "Wavefolder (Python)", number: 12, resourceName: "preset_wavefolder", language: .python),
        Entry(name: "Wavefolder (Rust)", number: 13, resourceName: "preset_wavefolder_rust", language: .rust),
        Entry(name: "Bitcrush (Python)", number: 14, resourceName: "preset_bitcrush", language: .python),
        Entry(name: "Bitcrush (Rust)", number: 15, resourceName: "preset_bitcrush_rust", language: .rust),

        // Filters
        Entry(name: "Low-Pass Filter (Python)", number: 16, resourceName: "preset_lowpass", language: .python),
        Entry(name: "Low-Pass Filter (Rust)", number: 17, resourceName: "preset_lowpass_rust", language: .rust),
        Entry(name: "State Variable Filter (Python)", number: 18, resourceName: "preset_svf", language: .python),
        Entry(name: "State Variable Filter (Rust)", number: 19, resourceName: "preset_svf_rust", language: .rust),

        // Dynamics
        Entry(name: "Compressor (Python)", number: 20, resourceName: "preset_compressor", language: .python),
        Entry(name: "Compressor (Rust)", number: 21, resourceName: "preset_compressor_rust", language: .rust),
        Entry(name: "Limiter (Python)", number: 22, resourceName: "preset_limiter", language: .python),
        Entry(name: "Limiter (Rust)", number: 23, resourceName: "preset_limiter_rust", language: .rust),
        Entry(name: "Noise Gate (Python)", number: 24, resourceName: "preset_noisegate", language: .python),
        Entry(name: "Noise Gate (Rust)", number: 25, resourceName: "preset_noisegate_rust", language: .rust),

        // Modulation
        Entry(name: "Tremolo (Python)", number: 26, resourceName: "preset_tremolo", language: .python),
        Entry(name: "Tremolo (Rust)", number: 27, resourceName: "preset_tremolo_rust", language: .rust),
        Entry(name: "Chorus (Python)", number: 28, resourceName: "preset_chorus", language: .python),
        Entry(name: "Chorus (Rust)", number: 29, resourceName: "preset_chorus_rust", language: .rust),
        Entry(name: "Flanger (Python)", number: 30, resourceName: "preset_flanger", language: .python),
        Entry(name: "Flanger (Rust)", number: 31, resourceName: "preset_flanger_rust", language: .rust),
        Entry(name: "Phaser (Python)", number: 32, resourceName: "preset_phaser", language: .python),
        Entry(name: "Phaser (Rust)", number: 33, resourceName: "preset_phaser_rust", language: .rust),
        Entry(name: "Ring Modulator (Python)", number: 34, resourceName: "preset_ringmod", language: .python),
        Entry(name: "Ring Modulator (Rust)", number: 35, resourceName: "preset_ringmod_rust", language: .rust),

        // Delay / Time
        Entry(name: "Delay (Python)", number: 36, resourceName: "preset_delay", language: .python),
        Entry(name: "Delay (Rust)", number: 37, resourceName: "preset_delay_rust", language: .rust),
        Entry(name: "Ping-Pong Delay (Python)", number: 38, resourceName: "preset_pingpong", language: .python),
        Entry(name: "Ping-Pong Delay (Rust)", number: 39, resourceName: "preset_pingpong_rust", language: .rust),
        Entry(name: "Reverse Slicer (Python)", number: 40, resourceName: "preset_slicer", language: .python),
        Entry(name: "Reverse Slicer (Rust)", number: 41, resourceName: "preset_slicer_rust", language: .rust),

        // Generator
        Entry(name: "White Noise (Python)", number: 42, resourceName: "preset_whitenoise", language: .python),
        Entry(name: "White Noise (Rust)", number: 43, resourceName: "preset_whitenoise_rust", language: .rust),
    ]
}
