//
//  SpectrogramBitmapBuffer.swift
//  ConjureDSPTests
//
//  Minimal copy of SpectrogramBitmapBuffer from ConjureDSPExtension for unit testing.
//  The AU extension target can't be @testable-imported because it's an appex.
//

import CoreGraphics
import simd

final class SpectrogramBitmapBuffer {
    let width: Int
    let height: Int
    private(set) var writeColumn: Int = 0

    private let context: CGContext
    private let baseAddress: UnsafeMutablePointer<UInt8>
    private let bytesPerRow: Int

    init?(width: Int, height: Int, fillColor: SIMD4<UInt8> = SIMD4<UInt8>(0, 0, 0, 255)) {
        guard width > 0 && height > 0 else { return nil }
        self.width = width
        self.height = height

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        guard let data = ctx.data else { return nil }

        self.context = ctx
        self.bytesPerRow = ctx.bytesPerRow
        self.baseAddress = data.assumingMemoryBound(to: UInt8.self)

        let totalBytes = bytesPerRow * height
        for i in stride(from: 0, to: totalBytes, by: 4) {
            baseAddress[i] = fillColor.x
            baseAddress[i + 1] = fillColor.y
            baseAddress[i + 2] = fillColor.z
            baseAddress[i + 3] = fillColor.w
        }
    }

    func appendColumn(_ column: [SIMD4<UInt8>]) {
        guard column.count == height else { return }

        let col = writeColumn
        for y in 0..<height {
            let row = height - 1 - y
            let offset = row * bytesPerRow + col * 4
            let pixel = column[y]
            baseAddress[offset] = pixel.x
            baseAddress[offset + 1] = pixel.y
            baseAddress[offset + 2] = pixel.z
            baseAddress[offset + 3] = pixel.w
        }

        writeColumn = (col + 1) % width
    }

    func makeImage() -> CGImage? {
        context.makeImage()
    }
}
