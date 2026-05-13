//
//  SpectrogramColorMapTests.swift
//  ConjureDSPLogicTests
//
//  Pins the magma colormap's "silence is dark" contract: under the production
//  visual floor (−90 dB), off-fundamental Hann sidelobe content paints as
//  near-black rather than as the wide purple haze that the prior −120 dB
//  floor produced for a pure A440 source.
//

import Testing
import simd

struct SpectrogramColorMapTests {

    // Rec. 601 luminance — proxy for "how bright does this read to a viewer."
    // Magma reference points at floor=−90:
    //   db=−90 → index 0  → (13, 15, 26)   → L ≈ 15.5
    //   db=−80 → index 28 → (49, 36, 76)   → L ≈ 44.4
    //   db=−60 → index 84 → (~89, 73, 195) → L ≈ 91.6  (the screenshot's purple)
    //   db=−40 → index 156 → (~209, 132, 215) → L ≈ 164
    //   db=0   → index 255 → (255, 209, 102) → L ≈ 210
    // Threshold 50 cleanly separates "dark / reads as silence" (≤−80 dB) from
    // "visibly colored / reads as signal" (≥−60 dB).
    private func luminance(_ p: SIMD4<UInt8>) -> Float {
        0.299 * Float(p.x) + 0.587 * Float(p.y) + 0.114 * Float(p.z)
    }

    // MARK: - Floor contract

    @Test func farSidelobesReadAsSilence() {
        // Hann sidelobes for an A440 sine through a 2048-point window roll off
        // at ~18 dB/octave from a −32 dB first sidelobe; bins many octaves out
        // sit at −80 dB and below. Under floor=−90 these must read as silence
        // (low luminance), not as the wide purple haze the prior −120 dB floor
        // produced.
        for db: Float in [-100, -95, -90, -85, -80] {
            let pixel = SpectrogramColorMap.magmaForDB(db, floor: -90.0)
            let L = luminance(pixel)
            #expect(L < 50,
                    "db=\(db) under floor=-90 should read as silence (L<50), got L=\(L), pixel=\(pixel)")
        }
    }

    @Test func atFloorMapsToDeepestNavy() {
        // Exact-floor input must hit colormap index 0.
        let pixel = SpectrogramColorMap.magmaForDB(-90.0, floor: -90.0)
        #expect(pixel == SpectrogramColorMap.magma[0])
    }

    @Test func belowFloorClampsToBlackEnd() {
        let pixel = SpectrogramColorMap.magmaForDB(-150.0, floor: -90.0)
        let zero = SpectrogramColorMap.magma[0]
        #expect(pixel == zero, "dB below floor should saturate at index 0")
    }

    @Test func zeroDbMapsToBrightestEnd() {
        let pixel = SpectrogramColorMap.magmaForDB(0.0, floor: -90.0)
        let top = SpectrogramColorMap.magma[255]
        #expect(pixel == top, "0 dB should map to the brightest colormap entry")
    }

    // MARK: - Regression: prior −120 dB floor would have painted these purple

    @Test func priorFloorWouldHavePaintedSidelobesAsPurple() {
        // With the old floor of −120 dB, −60 dB maps to magma index 127, which
        // sits at the soft-purple anchor #B06EFF = (176, 110, 255). The blue
        // channel alone exceeds the navy ceiling, so this pixel is decidedly
        // not silence. The test pins this so future readers see the contrast
        // between old and new behavior.
        let oldFloorPixel = SpectrogramColorMap.magmaForDB(-60.0, floor: -120.0)
        #expect(oldFloorPixel.z > 200,
                "Under old floor=-120, -60 dB paints near-peak-blue purple, got \(oldFloorPixel)")

        // Same input under the new visual floor — silence.
        let newFloorPixel = SpectrogramColorMap.magmaForDB(-60.0, floor: -90.0)
        // -60 dB at floor=-90 normalizes to (−60 + 90)/90 = 0.333, index 84.
        // That's well into the navy→purple ramp; expect the blue channel to
        // be elevated but not yet purple-bright. We're not asserting silence
        // here — only that it's strictly darker than the old-floor render,
        // which is the user-visible behavior change.
        #expect(newFloorPixel.z < oldFloorPixel.z,
                "-60 dB under new floor should be darker than under old floor")
    }

    // MARK: - Near-floor monotonicity

    @Test func brighterInputProducesBrighterOrEqualPixel() {
        // Walking up from floor toward 0 dB, the blue channel should be
        // monotonically non-decreasing for the navy→purple→gold→back-toward-mid-blue
        // ramp until we reach the gold anchor at t=1.0. Walking the navy half
        // only (floor to mid) is enough to catch a sign-flipped mapping.
        let pixels: [SIMD4<UInt8>] = stride(from: Float(-90), through: -45, by: 5)
            .map { SpectrogramColorMap.magmaForDB($0, floor: -90.0) }

        for i in 1..<pixels.count {
            #expect(pixels[i].z >= pixels[i - 1].z,
                    "Magma blue channel should not decrease across navy→purple ramp; idx \(i-1)→\(i)")
        }
    }
}
