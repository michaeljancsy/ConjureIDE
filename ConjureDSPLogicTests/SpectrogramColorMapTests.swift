//
//  SpectrogramColorMapTests.swift
//  ConjureDSPLogicTests
//
//  Pins the re-anchored magma palette's "silence is dark" contract: the
//  four-anchor ramp (navy → dark plum → soft purple → gold) has its
//  perceptual-midpoint anchor sitting at low luminance (~0.16), so dB
//  values in the lower half of the spectrogram range read as dark instead
//  of the bright purple haze the previous two-segment ramp produced.
//
//  Tests run under the production floor (-120 dB), not a raised "visual"
//  floor — the palette itself is doing the work, not a compressed range.
//

import Testing
import simd

struct SpectrogramColorMapTests {

    // Rec. 601 luminance — proxy for "how bright does this read to a viewer."
    // Reference points under the re-anchored palette with floor=-120:
    //   db=-120 → t=0.00  → (13, 15, 26)    → L ≈ 15.5   (deep navy)
    //   db=-90  → t=0.25  → (43, 23, 69)    → L ≈ 34     (navy→plum mid)
    //   db=-60  → t=0.50  → (74, 31, 112)   → L ≈ 53     (dark plum)
    //   db=-40  → t=0.667 → (142, 84, 207)  → L ≈ 115    (purple, signal)
    //   db=-30  → t=0.75  → (176, 110, 255) → L ≈ 146    (brand soft purple)
    //   db=-15  → t=0.875 → (216, 159, 178) → L ≈ 178
    //   db=0    → t=1.00  → (255, 209, 102) → L ≈ 210    (gold, peak)
    private func luminance(_ p: SIMD4<UInt8>) -> Float {
        0.299 * Float(p.x) + 0.587 * Float(p.y) + 0.114 * Float(p.z)
    }

    // MARK: - Low-dB content reads as dark

    @Test func lowEnergyBinsReadAsDarkUnderProductionFloor() {
        // Under the production setup (visualFloor=-90, re-anchored palette),
        // sub-audibility content paints as dark. At floor=-90:
        //   -90 dB → t=0.0  → navy           (L ≈ 15)
        //   -80 dB → t=0.111 → navy-plum mid (L ≈ 21)
        //   -60 dB → t=0.333 → segment 1     (L ≈ 41)
        for db: Float in [-100, -90, -80, -70, -60] {
            let pixel = SpectrogramColorMap.magmaForDB(db, floor: -90.0)
            let L = luminance(pixel)
            #expect(L < 60,
                    "db=\(db) under visualFloor=-90 should be visibly dark (L<60), got L=\(L), pixel=\(pixel)")
        }
    }

    @Test func lowEnergyAlsoDarkUnderRawFloor() {
        // Even at the un-compressed floorDB=-120 the re-anchored palette
        // keeps the lower half (≤ -60 dB) in the navy→plum range. This
        // catches a future regression that swaps anchors and brightens
        // the midpoint without touching the floor.
        for db: Float in [-120, -100, -80, -60] {
            let pixel = SpectrogramColorMap.magmaForDB(db, floor: -120.0)
            let L = luminance(pixel)
            #expect(L < 60,
                    "db=\(db) under floor=-120 should still be visibly dark (L<60), got L=\(L), pixel=\(pixel)")
        }
    }

    @Test func midDbContentIsVisibleButNotPeak() {
        // -30 dB should clearly register as signal (the brand purple anchor),
        // but is not yet at the gold peak. Pin both edges.
        let pixel = SpectrogramColorMap.magmaForDB(-30.0, floor: -120.0)
        let L = luminance(pixel)
        #expect(L > 100, "−30 dB should render as visible signal; L=\(L)")
        #expect(L < 200, "−30 dB shouldn't read as full peak; L=\(L)")
    }

    @Test func zeroDbMapsToGoldPeak() {
        let pixel = SpectrogramColorMap.magmaForDB(0.0, floor: -120.0)
        #expect(pixel == SpectrogramColorMap.magma[255])
        // Pin the actual gold values — catches an accidental anchor swap.
        #expect(pixel.x == 255)
        #expect(pixel.y >= 200 && pixel.y <= 215)
        #expect(pixel.z >= 95 && pixel.z <= 110)
    }

    // MARK: - Floor contract

    @Test func atFloorMapsToDeepestNavy() {
        let pixel = SpectrogramColorMap.magmaForDB(-120.0, floor: -120.0)
        #expect(pixel == SpectrogramColorMap.magma[0])
    }

    @Test func belowFloorClampsToBlackEnd() {
        let pixel = SpectrogramColorMap.magmaForDB(-150.0, floor: -120.0)
        #expect(pixel == SpectrogramColorMap.magma[0])
    }

    // MARK: - Regression: old palette painted -60 dB as bright purple

    @Test func reanchoredPaletteIsDarkerThanOldAtMidpoint() {
        // Old palette at t=0.5 was #B06EFF (brand soft purple), L≈146.
        // New palette at t=0.5 is dark plum, L should be < 60. We can't
        // run the old palette here (test mirror only ships the new one),
        // but we can pin the numerical contract: under the new palette
        // the brightest channel at the perceptual midpoint is well below
        // what the old palette produced.
        let midPixel = SpectrogramColorMap.magma[127]  // t ≈ 0.498
        #expect(midPixel.z < 128,
                "Re-anchored magma mid should not exceed half-brightness blue; got \(midPixel)")
        #expect(luminance(midPixel) < 60,
                "Re-anchored magma mid luminance should be < 60; got \(luminance(midPixel))")
    }

    // MARK: - Monotonicity

    @Test func luminanceIsMonotonicNonDecreasing() {
        // Walking up from index 0 to 255, luminance should never decrease.
        // Catches anchor inversions or color-channel sign flips.
        var prevL: Float = -1
        for i in 0..<256 {
            let L = luminance(SpectrogramColorMap.magma[i])
            #expect(L >= prevL - 0.5,
                    "Magma luminance decreased at index \(i): \(prevL) → \(L)")
            prevL = L
        }
    }
}
