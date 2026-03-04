//
//  SpectrogramView.swift
//  BearBoneExtension
//
//  Renders a scrolling waterfall spectrogram using a CGContext-backed bitmap.
//

import SwiftUI

/// Which signal to display in the spectrogram.
enum SpectrogramChannel {
    case input
    case output
    case difference
}

/// Renders a single scrolling waterfall spectrogram from FFT magnitude data.
///
/// Maintains a pixel buffer that scrolls left each time new FFT data arrives.
/// New frequency columns are drawn on the right edge.
struct SpectrogramView: View {
    @ObservedObject var captureManager: AudioCaptureManager
    let channel: SpectrogramChannel
    var frequencyScale: FrequencyScale = .log
    var isDifference: Bool { channel == .difference }

    /// Number of time columns visible in the waterfall
    private static let columnCount = 256

    @State private var pixelBuffer: SpectrogramPixelBuffer?

    var body: some View {
        GeometryReader { geometry in
            let width = Int(geometry.size.width)
            let height = Int(geometry.size.height)

            Canvas { context, size in
                guard let buffer = pixelBuffer, let image = buffer.makeImage() else { return }
                context.draw(Image(image, scale: 1, label: Text("")), in: CGRect(origin: .zero, size: size))
            }
            .onChange(of: captureManager.updateCounter) { _, _ in
                ensureBuffer(width: width, height: height)
                let mags = magnitudes
                if !mags.isEmpty {
                    appendColumn(magnitudes: mags, height: height)
                }
            }
            .onChange(of: geometry.size) { _, newSize in
                let w = Int(newSize.width)
                let h = Int(newSize.height)
                if w > 0 && h > 0 {
                    pixelBuffer = SpectrogramPixelBuffer(width: w, height: h)
                }
            }
            .onAppear {
                if width > 0 && height > 0 {
                    pixelBuffer = SpectrogramPixelBuffer(width: width, height: height)
                }
            }
        }
        .accessibilityIdentifier("spectrogramView_\(channelName)")
    }

    private var channelName: String {
        switch channel {
        case .input: return "input"
        case .output: return "output"
        case .difference: return "difference"
        }
    }

    private var magnitudes: [Float] {
        switch channel {
        case .input: return captureManager.inputMagnitudes
        case .output: return captureManager.outputMagnitudes
        case .difference: return captureManager.differenceMagnitudes
        }
    }

    private func ensureBuffer(width: Int, height: Int) {
        if pixelBuffer == nil && width > 0 && height > 0 {
            pixelBuffer = SpectrogramPixelBuffer(width: width, height: height)
        }
    }

    private func appendColumn(magnitudes: [Float], height: Int) {
        guard var buffer = pixelBuffer else { return }
        let binCount = magnitudes.count
        guard binCount > 0 && height > 0 else { return }

        // Build a column of pixels (bottom to top)
        var column = [SIMD4<UInt8>](repeating: .zero, count: height)

        for y in 0..<height {
            // Map pixel y (0 = bottom) to FFT bin using frequency scale
            let normalizedY = Float(y) / Float(height)

            // Inverse map from display position to frequency bin
            let bin = inverseBinMapping(displayPos: normalizedY, binCount: binCount)
            let binIndex = min(max(Int(bin), 0), binCount - 1)

            let value = magnitudes[binIndex]

            if isDifference {
                column[y] = SpectrogramColorMap.divergingForDB(value, range: 40.0)
            } else {
                column[y] = SpectrogramColorMap.magmaForDB(value, floor: AudioCaptureManager.floorDB)
            }
        }

        buffer.shiftLeftAndAppend(column: column)
        pixelBuffer = buffer
    }

    /// Map a display position (0...1, bottom to top) back to an FFT bin index.
    private func inverseBinMapping(displayPos: Float, binCount: Int) -> Float {
        let minFreqNorm: Float = 20.0 / 22050.0

        let normalizedFreq: Float
        switch frequencyScale {
        case .linear:
            normalizedFreq = displayPos

        case .log:
            let logMin = log2(minFreqNorm)
            let logMax: Float = 0.0 // log2(1.0)
            let logVal = logMin + displayPos * (logMax - logMin)
            normalizedFreq = pow(2.0, logVal)

        case .mel:
            let melMin = 2595.0 * log10(1.0 + minFreqNorm * 22050.0 / 700.0)
            let melMax = 2595.0 * log10(1.0 + 22050.0 / 700.0) as Float
            let melVal = melMin + displayPos * (melMax - melMin)
            let hzVal = 700.0 * (pow(10.0, melVal / 2595.0) - 1.0)
            normalizedFreq = hzVal / 22050.0
        }

        return normalizedFreq * Float(binCount)
    }
}

// MARK: - Pixel Buffer

/// A bitmap buffer for waterfall spectrogram rendering.
/// Stores RGBA pixel data and supports efficient left-shift + append operations.
struct SpectrogramPixelBuffer {
    let width: Int
    let height: Int
    /// Row-major pixel data: pixels[y * width + x] where y=0 is bottom.
    var pixels: [SIMD4<UInt8>]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.pixels = [SIMD4<UInt8>](repeating: SIMD4(0, 0, 0, 255), count: width * height)
    }

    /// Shift all columns left by 1 pixel, then write `column` at the right edge.
    /// `column` has `height` entries where index 0 = bottom.
    mutating func shiftLeftAndAppend(column: [SIMD4<UInt8>]) {
        guard column.count == height else { return }

        // Shift each row left by 1
        for y in 0..<height {
            let rowStart = y * width
            // memmove within the row
            for x in 0..<(width - 1) {
                pixels[rowStart + x] = pixels[rowStart + x + 1]
            }
            // Write new column on the right edge
            pixels[rowStart + width - 1] = column[y]
        }
    }

    /// Create a CGImage from the pixel buffer.
    func makeImage() -> CGImage? {
        // Flip vertically: pixel buffer has y=0 at bottom, CGImage has y=0 at top
        var flipped = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let srcRow = y
            let dstRow = height - 1 - y
            for x in 0..<width {
                let srcIdx = srcRow * width + x
                let dstIdx = (dstRow * width + x) * 4
                let pixel = pixels[srcIdx]
                flipped[dstIdx] = pixel.x     // R
                flipped[dstIdx + 1] = pixel.y // G
                flipped[dstIdx + 2] = pixel.z // B
                flipped[dstIdx + 3] = pixel.w // A
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &flipped,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        return context.makeImage()
    }
}
