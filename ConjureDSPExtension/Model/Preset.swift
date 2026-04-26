import Foundation

/// Effect category for organizing presets in the browser.
enum PresetCategory: String, CaseIterable, Hashable, Identifiable {
    case utility
    case distortion
    case filters
    case dynamics
    case modulation
    case delay
    case generator
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .utility: return "Utility"
        case .distortion: return "Distortion / Saturation"
        case .filters: return "Filters"
        case .dynamics: return "Dynamics"
        case .modulation: return "Modulation"
        case .delay: return "Delay / Time"
        case .generator: return "Generator"
        case .other: return "Other"
        }
    }
}

/// A named DSP script preset — either bundled (factory) or user-authored (user).
/// User presets live inside a git repo under the App Group's `Presets/` directory.
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
    var category: PresetCategory?
    var descriptionText: String?
    var author: String?

    var isFactory: Bool {
        if case .factory = source { return true }
        return false
    }

    var isUser: Bool {
        if case .user = source { return true }
        return false
    }

    /// On-disk URL for mutable presets (nil for factory).
    var fileURL: URL? {
        if case .user(let url) = source { return url }
        return nil
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
        let category: PresetCategory
    }

    static let entries: [Entry] = [
        // Utility
        Entry(name: "Passthrough (Python)", number: 0, resourceName: "preset_passthrough", language: .python, category: .utility),
        Entry(name: "Passthrough (Rust)", number: 1, resourceName: "preset_passthrough_rust", language: .rust, category: .utility),
        Entry(name: "Gain + Pan (Python)", number: 2, resourceName: "preset_gainpan", language: .python, category: .utility),
        Entry(name: "Gain + Pan (Rust)", number: 3, resourceName: "preset_gainpan_rust", language: .rust, category: .utility),
        Entry(name: "DC Blocker (Python)", number: 4, resourceName: "preset_dcblocker", language: .python, category: .utility),
        Entry(name: "DC Blocker (Rust)", number: 5, resourceName: "preset_dcblocker_rust", language: .rust, category: .utility),
        Entry(name: "Stereo Width (Python)", number: 6, resourceName: "preset_stereowidth", language: .python, category: .utility),
        Entry(name: "Stereo Width (Rust)", number: 7, resourceName: "preset_stereowidth_rust", language: .rust, category: .utility),
        Entry(name: "Stereo Width Optimized (Python)", number: 44, resourceName: "preset_stereowidth_optimized", language: .python, category: .utility),

        // Distortion / Saturation
        Entry(name: "Soft Clip (Python)", number: 8, resourceName: "preset_softclip", language: .python, category: .distortion),
        Entry(name: "Soft Clip (Rust)", number: 9, resourceName: "preset_softclip_rust", language: .rust, category: .distortion),
        Entry(name: "Hard Clip (Python)", number: 10, resourceName: "preset_hardclip", language: .python, category: .distortion),
        Entry(name: "Hard Clip (Rust)", number: 11, resourceName: "preset_hardclip_rust", language: .rust, category: .distortion),
        Entry(name: "Wavefolder (Python)", number: 12, resourceName: "preset_wavefolder", language: .python, category: .distortion),
        Entry(name: "Wavefolder (Rust)", number: 13, resourceName: "preset_wavefolder_rust", language: .rust, category: .distortion),
        Entry(name: "Bitcrush (Python)", number: 14, resourceName: "preset_bitcrush", language: .python, category: .distortion),
        Entry(name: "Bitcrush (Rust)", number: 15, resourceName: "preset_bitcrush_rust", language: .rust, category: .distortion),

        // Filters
        Entry(name: "Low-Pass Filter (Python)", number: 16, resourceName: "preset_lowpass", language: .python, category: .filters),
        Entry(name: "Low-Pass Filter (Rust)", number: 17, resourceName: "preset_lowpass_rust", language: .rust, category: .filters),
        Entry(name: "State Variable Filter (Python)", number: 18, resourceName: "preset_svf", language: .python, category: .filters),
        Entry(name: "State Variable Filter (Rust)", number: 19, resourceName: "preset_svf_rust", language: .rust, category: .filters),
        Entry(name: "3-Band EQ (Python)", number: 45, resourceName: "preset_eq3", language: .python, category: .filters),
        Entry(name: "3-Band EQ (Rust)", number: 46, resourceName: "preset_eq3_rust", language: .rust, category: .filters),

        // Dynamics
        Entry(name: "Compressor (Python)", number: 20, resourceName: "preset_compressor", language: .python, category: .dynamics),
        Entry(name: "Compressor (Rust)", number: 21, resourceName: "preset_compressor_rust", language: .rust, category: .dynamics),
        Entry(name: "Limiter (Python)", number: 22, resourceName: "preset_limiter", language: .python, category: .dynamics),
        Entry(name: "Limiter (Rust)", number: 23, resourceName: "preset_limiter_rust", language: .rust, category: .dynamics),
        Entry(name: "Noise Gate (Python)", number: 24, resourceName: "preset_noisegate", language: .python, category: .dynamics),
        Entry(name: "Noise Gate (Rust)", number: 25, resourceName: "preset_noisegate_rust", language: .rust, category: .dynamics),
        Entry(name: "De-esser (Python)", number: 47, resourceName: "preset_deesser", language: .python, category: .dynamics),
        Entry(name: "De-esser (Rust)", number: 48, resourceName: "preset_deesser_rust", language: .rust, category: .dynamics),
        Entry(name: "Lookahead Limiter (Python)", number: 51, resourceName: "preset_lookahead_limiter", language: .python, category: .dynamics),
        Entry(name: "Lookahead Limiter (Rust)", number: 52, resourceName: "preset_lookahead_limiter_rust", language: .rust, category: .dynamics),

        // Modulation
        Entry(name: "Tremolo (Python)", number: 26, resourceName: "preset_tremolo", language: .python, category: .modulation),
        Entry(name: "Tremolo (Rust)", number: 27, resourceName: "preset_tremolo_rust", language: .rust, category: .modulation),
        Entry(name: "Chorus (Python)", number: 28, resourceName: "preset_chorus", language: .python, category: .modulation),
        Entry(name: "Chorus (Rust)", number: 29, resourceName: "preset_chorus_rust", language: .rust, category: .modulation),
        Entry(name: "Flanger (Python)", number: 30, resourceName: "preset_flanger", language: .python, category: .modulation),
        Entry(name: "Flanger (Rust)", number: 31, resourceName: "preset_flanger_rust", language: .rust, category: .modulation),
        Entry(name: "Phaser (Python)", number: 32, resourceName: "preset_phaser", language: .python, category: .modulation),
        Entry(name: "Phaser (Rust)", number: 33, resourceName: "preset_phaser_rust", language: .rust, category: .modulation),
        Entry(name: "Ring Modulator (Python)", number: 34, resourceName: "preset_ringmod", language: .python, category: .modulation),
        Entry(name: "Ring Modulator (Rust)", number: 35, resourceName: "preset_ringmod_rust", language: .rust, category: .modulation),
        Entry(name: "Auto-Wah (Python)", number: 49, resourceName: "preset_wah", language: .python, category: .modulation),
        Entry(name: "Auto-Wah (Rust)", number: 50, resourceName: "preset_wah_rust", language: .rust, category: .modulation),

        // Delay / Time
        Entry(name: "Delay (Python)", number: 36, resourceName: "preset_delay", language: .python, category: .delay),
        Entry(name: "Delay (Rust)", number: 37, resourceName: "preset_delay_rust", language: .rust, category: .delay),
        Entry(name: "Ping-Pong Delay (Python)", number: 38, resourceName: "preset_pingpong", language: .python, category: .delay),
        Entry(name: "Ping-Pong Delay (Rust)", number: 39, resourceName: "preset_pingpong_rust", language: .rust, category: .delay),
        Entry(name: "Reverse Slicer (Python)", number: 40, resourceName: "preset_slicer", language: .python, category: .delay),
        Entry(name: "Reverse Slicer (Rust)", number: 41, resourceName: "preset_slicer_rust", language: .rust, category: .delay),

        // Generator
        Entry(name: "White Noise (Python)", number: 42, resourceName: "preset_whitenoise", language: .python, category: .generator),
        Entry(name: "White Noise (Rust)", number: 43, resourceName: "preset_whitenoise_rust", language: .rust, category: .generator),

        // NAM / Amp Modeling
        Entry(name: "NAM Tone (Python)", number: 53, resourceName: "preset_nam", language: .python, category: .other),
        Entry(name: "NAM Tone (Rust)", number: 54, resourceName: "preset_nam_rust", language: .rust, category: .other),

        // Creative / Hero
        Entry(name: "Haunted Cathedral (Python)", number: 55, resourceName: "preset_haunted_cathedral", language: .python, category: .other),
        Entry(name: "Haunted Cathedral (Rust)", number: 56, resourceName: "preset_haunted_cathedral_rust", language: .rust, category: .other),
        Entry(name: "Dying Star (Python)", number: 57, resourceName: "preset_dying_star", language: .python, category: .other),
        Entry(name: "Dying Star (Rust)", number: 58, resourceName: "preset_dying_star_rust", language: .rust, category: .other),
        Entry(name: "Broken Fax Lullaby (Python)", number: 59, resourceName: "preset_broken_fax_lullaby", language: .python, category: .other),
        Entry(name: "Broken Fax Lullaby (Rust)", number: 60, resourceName: "preset_broken_fax_lullaby_rust", language: .rust, category: .other),
        Entry(name: "Sun-Baked Cassette (Python)", number: 61, resourceName: "preset_sunbaked_cassette", language: .python, category: .other),
        Entry(name: "Sun-Baked Cassette (Rust)", number: 62, resourceName: "preset_sunbaked_cassette_rust", language: .rust, category: .other),
        Entry(name: "Alien Radio (Python)", number: 63, resourceName: "preset_alien_radio", language: .python, category: .other),
        Entry(name: "Alien Radio (Rust)", number: 64, resourceName: "preset_alien_radio_rust", language: .rust, category: .other),
        Entry(name: "Underwater Spy (Python)", number: 65, resourceName: "preset_underwater_spy", language: .python, category: .other),
        Entry(name: "Underwater Spy (Rust)", number: 66, resourceName: "preset_underwater_spy_rust", language: .rust, category: .other),
        Entry(name: "Glass Smash (Python)", number: 67, resourceName: "preset_glass_smash", language: .python, category: .other),
        Entry(name: "Glass Smash (Rust)", number: 68, resourceName: "preset_glass_smash_rust", language: .rust, category: .other),
        Entry(name: "Ghost Choir (Python)", number: 69, resourceName: "preset_ghost_choir", language: .python, category: .other),
        Entry(name: "Ghost Choir (Rust)", number: 70, resourceName: "preset_ghost_choir_rust", language: .rust, category: .other),
        Entry(name: "Burial at Sea (Python)", number: 71, resourceName: "preset_burial_at_sea", language: .python, category: .other),
        Entry(name: "Burial at Sea (Rust)", number: 72, resourceName: "preset_burial_at_sea_rust", language: .rust, category: .other),
        Entry(name: "Black Hole Vespers (Python)", number: 73, resourceName: "preset_black_hole_vespers", language: .python, category: .other),
        Entry(name: "Black Hole Vespers (Rust)", number: 74, resourceName: "preset_black_hole_vespers_rust", language: .rust, category: .other),
        Entry(name: "Astronaut's Garden (Python)", number: 75, resourceName: "preset_astronauts_garden", language: .python, category: .other),
        Entry(name: "Astronaut's Garden (Rust)", number: 76, resourceName: "preset_astronauts_garden_rust", language: .rust, category: .other),
        Entry(name: "Permafrost Dream (Python)", number: 77, resourceName: "preset_permafrost_dream", language: .python, category: .other),
        Entry(name: "Permafrost Dream (Rust)", number: 78, resourceName: "preset_permafrost_dream_rust", language: .rust, category: .other),
        Entry(name: "Termite Cathedral (Python)", number: 79, resourceName: "preset_termite_cathedral", language: .python, category: .other),
        Entry(name: "Termite Cathedral (Rust)", number: 80, resourceName: "preset_termite_cathedral_rust", language: .rust, category: .other),
        Entry(name: "Whalebone Organ (Python)", number: 81, resourceName: "preset_whalebone_organ", language: .python, category: .other),
        Entry(name: "Whalebone Organ (Rust)", number: 82, resourceName: "preset_whalebone_organ_rust", language: .rust, category: .other),
        Entry(name: "Mothlight (Python)", number: 83, resourceName: "preset_mothlight", language: .python, category: .other),
        Entry(name: "Mothlight (Rust)", number: 84, resourceName: "preset_mothlight_rust", language: .rust, category: .other),
        Entry(name: "Morphine Drip (Python)", number: 85, resourceName: "preset_morphine_drip", language: .python, category: .other),
        Entry(name: "Morphine Drip (Rust)", number: 86, resourceName: "preset_morphine_drip_rust", language: .rust, category: .other),
        Entry(name: "Plague Doctor (Python)", number: 87, resourceName: "preset_plague_doctor", language: .python, category: .other),
        Entry(name: "Plague Doctor (Rust)", number: 88, resourceName: "preset_plague_doctor_rust", language: .rust, category: .other),
        Entry(name: "Geiger Bells (Python)", number: 89, resourceName: "preset_geiger_bells", language: .python, category: .other),
        Entry(name: "Geiger Bells (Rust)", number: 90, resourceName: "preset_geiger_bells_rust", language: .rust, category: .other),
        Entry(name: "Rusted Carousel (Python)", number: 91, resourceName: "preset_rusted_carousel", language: .python, category: .other),
        Entry(name: "Rusted Carousel (Rust)", number: 92, resourceName: "preset_rusted_carousel_rust", language: .rust, category: .other),
        Entry(name: "Last Transmission (Python)", number: 93, resourceName: "preset_last_transmission", language: .python, category: .other),
        Entry(name: "Last Transmission (Rust)", number: 94, resourceName: "preset_last_transmission_rust", language: .rust, category: .other),
        Entry(name: "Tin Can Telephone (Python)", number: 95, resourceName: "preset_tin_can_telephone", language: .python, category: .other),
        Entry(name: "Tin Can Telephone (Rust)", number: 96, resourceName: "preset_tin_can_telephone_rust", language: .rust, category: .other),
        Entry(name: "Acid Sermon (Python)", number: 97, resourceName: "preset_acid_sermon", language: .python, category: .other),
        Entry(name: "Acid Sermon (Rust)", number: 98, resourceName: "preset_acid_sermon_rust", language: .rust, category: .other),
        Entry(name: "Hailstorm Lullaby (Python)", number: 99, resourceName: "preset_hailstorm_lullaby", language: .python, category: .other),
        Entry(name: "Hailstorm Lullaby (Rust)", number: 100, resourceName: "preset_hailstorm_lullaby_rust", language: .rust, category: .other),
        Entry(name: "Methane Sea (Python)", number: 101, resourceName: "preset_methane_sea", language: .python, category: .other),
        Entry(name: "Methane Sea (Rust)", number: 102, resourceName: "preset_methane_sea_rust", language: .rust, category: .other),
        Entry(name: "Mockingbird at Night (Rust)", number: 103, resourceName: "preset_mockingbird_at_night_rust", language: .rust, category: .other),

        // Diagnostics — manual smoke test for the DSP→UI telemetry channel.
        // Passes a Drive-scaled signal through and publishes per-block
        // peak + envelope-follower output via `frame.telemetry`. Both
        // language variants share the same UI so the keys (`Peak Db`,
        // `Envelope Db`) are interchangeable.
        Entry(name: "Telemetry Smoke (Rust)", number: 104, resourceName: "preset_telemetry_smoke", language: .rust, category: .utility),
        Entry(name: "Telemetry Smoke (Python)", number: 105, resourceName: "preset_telemetry_smoke_python", language: .python, category: .utility),
    ]
}
