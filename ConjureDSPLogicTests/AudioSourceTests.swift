//
//  AudioSourceTests.swift
//  ConjureDSPLogicTests
//
//  Round-trip encode/decode for AudioSourcePersistence + a couple of
//  malformed-input cases. The persistence string lives in UserDefaults so
//  forwards-compatibility is on us, not the system.
//

import Foundation
import Testing

@Suite struct AudioSourceTests {

    @Test func builtInRoundTrip() {
        for source in BuiltInAudioSource.allCases {
            let encoded = AudioSourcePersistence.encode(.builtIn(source))
            #expect(encoded == "builtin:\(source.rawValue)")
            #expect(AudioSourcePersistence.decode(encoded) == .builtIn(source))
        }
    }

    @Test func externalRoundTripSimplePath() {
        let url = URL(fileURLWithPath: "/Users/x/sound.wav")
        let encoded = AudioSourcePersistence.encode(.external(url))
        #expect(encoded == "external:/Users/x/sound.wav")
        #expect(AudioSourcePersistence.decode(encoded) == .external(url))
    }

    @Test func externalPathWithColonsSurvivesRoundTrip() {
        // Colons are legal in macOS paths (rare but legal). maxSplits:1 in the
        // decoder is what makes this work — split with no limit would lose
        // every segment after the second `:`.
        let url = URL(fileURLWithPath: "/Users/x/weird:name:here.wav")
        let encoded = AudioSourcePersistence.encode(.external(url))
        let decoded = AudioSourcePersistence.decode(encoded)
        #expect(decoded == .external(url))
    }

    @Test func decodeRejectsEmptyString() {
        #expect(AudioSourcePersistence.decode("") == nil)
    }

    @Test func decodeRejectsMissingColon() {
        #expect(AudioSourcePersistence.decode("builtin") == nil)
        #expect(AudioSourcePersistence.decode("a440Sine") == nil)
    }

    @Test func decodeRejectsUnknownTag() {
        #expect(AudioSourcePersistence.decode("preset:foo") == nil)
        #expect(AudioSourcePersistence.decode(":foo") == nil)
    }

    @Test func decodeRejectsUnknownBuiltInRawValue() {
        #expect(AudioSourcePersistence.decode("builtin:nonsense") == nil)
        // The display name is not the raw value — must use the case name.
        #expect(AudioSourcePersistence.decode("builtin:A440 Sine") == nil)
    }

    @Test func decodeRejectsEmptyExternalPath() {
        #expect(AudioSourcePersistence.decode("external:") == nil)
    }

    @Test func displayNamesAreStable() {
        #expect(BuiltInAudioSource.a440Sine.displayName == "A440 Sine")
        #expect(BuiltInAudioSource.synth.displayName == "Synth")
        #expect(BuiltInAudioSource.whiteNoise.displayName == "White Noise")
        #expect(BuiltInAudioSource.a55Series.displayName == "A55 Sawtooth Series")
        #expect(BuiltInAudioSource.aOctaveStack.displayName == "A Octave Stack")
    }

    @Test func resourceMappingMatchesFilesOnDisk() {
        // Just sanity-check the (name, ext) tuple shape — actual file existence
        // is verified by the host app at launch.
        #expect(BuiltInAudioSource.a440Sine.resource.name == "a440_sine")
        #expect(BuiltInAudioSource.a440Sine.resource.ext == "wav")
        #expect(BuiltInAudioSource.synth.resource.name == "Synth")
        #expect(BuiltInAudioSource.synth.resource.ext == "aif")
    }
}
