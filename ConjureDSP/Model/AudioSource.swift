//
//  AudioSource.swift
//  ConjureDSP
//
//  The audio source feeding the host app's preview player. Either a curated
//  built-in test signal (bundled in the host app's Resources) or an external
//  file the user picked via the file importer. Foundation-only — symlinked
//  into ConjureDSPLogicTests so persistence encode/decode can be unit-tested
//  without host-app dependencies.
//

import Foundation

enum BuiltInAudioSource: String, CaseIterable, Identifiable {
    case a440Sine
    case whiteNoise
    case a55Series
    case aOctaveStack
    case synth

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .a440Sine: return "A440 Sine"
        case .whiteNoise: return "White Noise"
        case .a55Series: return "A55 Sawtooth Series"
        case .aOctaveStack: return "A Octave Stack"
        case .synth: return "Synth"
        }
    }

    var resource: (name: String, ext: String) {
        switch self {
        case .a440Sine: return ("a440_sine", "wav")
        case .whiteNoise: return ("white_noise", "wav")
        case .a55Series: return ("a55_sawtooth_series", "wav")
        case .aOctaveStack: return ("a_octave_stack", "wav")
        case .synth: return ("Synth", "aif")
        }
    }
}

enum AudioSource: Equatable {
    case builtIn(BuiltInAudioSource)
    case external(URL)

    var displayName: String {
        switch self {
        case .builtIn(let source): return source.displayName
        case .external(let url): return url.lastPathComponent
        }
    }
}

/// Pure functions for UserDefaults persistence — testable.
///
/// Encoding: `"builtin:<rawValue>"` or `"external:<absolute-path>"`. Decode
/// splits on the first `:` only, because external paths may legally contain
/// colons.
enum AudioSourcePersistence {
    static func encode(_ source: AudioSource) -> String {
        switch source {
        case .builtIn(let builtIn): return "builtin:\(builtIn.rawValue)"
        case .external(let url): return "external:\(url.path)"
        }
    }

    static func decode(_ raw: String) -> AudioSource? {
        let parts = raw.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let tag = String(parts[0])
        let body = String(parts[1])
        switch tag {
        case "builtin":
            guard let source = BuiltInAudioSource(rawValue: body) else { return nil }
            return .builtIn(source)
        case "external":
            guard !body.isEmpty else { return nil }
            return .external(URL(fileURLWithPath: body))
        default:
            return nil
        }
    }
}
