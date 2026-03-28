//
//  SpectrogramTests.swift
//  ConjureDSPTests
//

import CoreGraphics
import Testing

struct SpectrogramBitmapBufferTests {

    // MARK: - Initialization

    @Test func initWithValidDimensions() {
        let buffer = SpectrogramBitmapBuffer(width: 100, height: 50)
        #expect(buffer != nil)
        #expect(buffer?.width == 100)
        #expect(buffer?.height == 50)
        #expect(buffer?.writeColumn == 0)
    }

    @Test func initWithZeroDimensionsReturnsNil() {
        #expect(SpectrogramBitmapBuffer(width: 0, height: 50) == nil)
        #expect(SpectrogramBitmapBuffer(width: 100, height: 0) == nil)
        #expect(SpectrogramBitmapBuffer(width: 0, height: 0) == nil)
    }

    @Test func initWithNegativeDimensionsReturnsNil() {
        #expect(SpectrogramBitmapBuffer(width: -1, height: 50) == nil)
        #expect(SpectrogramBitmapBuffer(width: 100, height: -1) == nil)
    }

    // MARK: - makeImage

    @Test func makeImageReturnsValidCGImage() {
        let buffer = SpectrogramBitmapBuffer(width: 64, height: 32)!
        let image = buffer.makeImage()
        #expect(image != nil)
        #expect(image?.width == 64)
        #expect(image?.height == 32)
    }

    @Test func makeImageAfterColumnsStillValid() {
        let buffer = SpectrogramBitmapBuffer(width: 10, height: 4)!
        let col = [SIMD4<UInt8>](repeating: SIMD4(255, 0, 0, 255), count: 4)
        for _ in 0..<5 {
            buffer.appendColumn(col)
        }
        let image = buffer.makeImage()
        #expect(image != nil)
        #expect(image?.width == 10)
        #expect(image?.height == 4)
    }

    // MARK: - Cursor advancement

    @Test func writeColumnAdvancesOnAppend() {
        let buffer = SpectrogramBitmapBuffer(width: 10, height: 4)!
        let col = [SIMD4<UInt8>](repeating: SIMD4(128, 128, 128, 255), count: 4)

        #expect(buffer.writeColumn == 0)
        buffer.appendColumn(col)
        #expect(buffer.writeColumn == 1)
        buffer.appendColumn(col)
        #expect(buffer.writeColumn == 2)
    }

    @Test func writeColumnWrapsAtWidth() {
        let width = 8
        let buffer = SpectrogramBitmapBuffer(width: width, height: 2)!
        let col = [SIMD4<UInt8>](repeating: SIMD4(0, 0, 0, 255), count: 2)

        for _ in 0..<width {
            buffer.appendColumn(col)
        }
        #expect(buffer.writeColumn == 0)

        buffer.appendColumn(col)
        #expect(buffer.writeColumn == 1)
    }

    @Test func writeColumnWrapsMultipleTimes() {
        let width = 4
        let buffer = SpectrogramBitmapBuffer(width: width, height: 2)!
        let col = [SIMD4<UInt8>](repeating: SIMD4(0, 0, 0, 255), count: 2)

        // Write 2.5x the buffer width
        for _ in 0..<(width * 2 + 2) {
            buffer.appendColumn(col)
        }
        #expect(buffer.writeColumn == 2)
    }

    // MARK: - Column size guard

    @Test func appendColumnWithWrongHeightIsIgnored() {
        let buffer = SpectrogramBitmapBuffer(width: 10, height: 4)!
        let wrongCol = [SIMD4<UInt8>](repeating: .zero, count: 3)
        buffer.appendColumn(wrongCol)
        // Cursor should not advance
        #expect(buffer.writeColumn == 0)
    }

    @Test func appendEmptyColumnIsIgnored() {
        let buffer = SpectrogramBitmapBuffer(width: 10, height: 4)!
        buffer.appendColumn([])
        #expect(buffer.writeColumn == 0)
    }

    // MARK: - Pixel content verification

    @Test func pixelsAreInitializedToOpaqueBlack() throws {
        let buffer = SpectrogramBitmapBuffer(width: 4, height: 4)!
        let image = try #require(buffer.makeImage())
        let pixels = readPixels(from: image)

        // Every pixel should be opaque black (0, 0, 0, 255)
        for pixel in pixels {
            #expect(pixel == SIMD4<UInt8>(0, 0, 0, 255))
        }
    }

    @Test func appendedColumnWritesCorrectPixels() throws {
        let buffer = SpectrogramBitmapBuffer(width: 4, height: 3)!

        // Write a red column
        let red = SIMD4<UInt8>(255, 0, 0, 255)
        buffer.appendColumn([SIMD4<UInt8>](repeating: red, count: 3))

        let image = try #require(buffer.makeImage())
        let pixels = readPixels(from: image)

        // Column 0 should be red, columns 1-3 should be black
        for y in 0..<3 {
            #expect(pixels[y * 4 + 0] == red, "pixel at (0, \(y)) should be red")
            for x in 1..<4 {
                #expect(pixels[y * 4 + x] == SIMD4<UInt8>(0, 0, 0, 255),
                        "pixel at (\(x), \(y)) should be black")
            }
        }
    }

    @Test func verticalOrientationIsFlipped() throws {
        // column[0] = bottom (lowest freq), column[height-1] = top (highest freq)
        // CGImage y=0 is top, so column[height-1] should appear in CGImage row 0
        let buffer = SpectrogramBitmapBuffer(width: 1, height: 3)!

        let col: [SIMD4<UInt8>] = [
            SIMD4(255, 0, 0, 255),   // bottom (low freq)
            SIMD4(0, 255, 0, 255),   // middle
            SIMD4(0, 0, 255, 255),   // top (high freq)
        ]
        buffer.appendColumn(col)

        let image = try #require(buffer.makeImage())
        let pixels = readPixels(from: image)

        // CGImage row 0 (top) should be blue (high freq = column[2])
        #expect(pixels[0] == SIMD4(0, 0, 255, 255))
        // CGImage row 1 (middle) should be green
        #expect(pixels[1] == SIMD4(0, 255, 0, 255))
        // CGImage row 2 (bottom) should be red (low freq = column[0])
        #expect(pixels[2] == SIMD4(255, 0, 0, 255))
    }

    @Test func circularOverwriteReplacesOldestColumn() throws {
        let buffer = SpectrogramBitmapBuffer(width: 3, height: 1)!
        let red = SIMD4<UInt8>(255, 0, 0, 255)
        let green = SIMD4<UInt8>(0, 255, 0, 255)
        let blue = SIMD4<UInt8>(0, 0, 255, 255)
        let white = SIMD4<UInt8>(255, 255, 255, 255)

        buffer.appendColumn([red])    // col 0 = red
        buffer.appendColumn([green])  // col 1 = green
        buffer.appendColumn([blue])   // col 2 = blue, cursor wraps to 0
        buffer.appendColumn([white])  // col 0 = white (overwrites red)

        let image = try #require(buffer.makeImage())
        let pixels = readPixels(from: image)

        // Raw buffer order: [white, green, blue]
        #expect(pixels[0] == white)
        #expect(pixels[1] == green)
        #expect(pixels[2] == blue)
    }

    // MARK: - Helpers

    /// Read all pixels from a CGImage as SIMD4<UInt8> in row-major order (y=0 at top).
    private func readPixels(from image: CGImage) -> [SIMD4<UInt8>] {
        let w = image.width
        let h = image.height
        var pixelData = [UInt8](repeating: 0, count: w * h * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixelData,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [] }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        var result = [SIMD4<UInt8>]()
        result.reserveCapacity(w * h)
        for i in stride(from: 0, to: pixelData.count, by: 4) {
            result.append(SIMD4(pixelData[i], pixelData[i+1], pixelData[i+2], pixelData[i+3]))
        }
        return result
    }
}
