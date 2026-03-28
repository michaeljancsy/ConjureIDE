//
//  SpectrogramView.swift
//  ConjureDSPExtension
//
//  Renders a scrolling waterfall spectrogram using a CGContext-backed bitmap.
//

import SwiftUI

/// Which signal to display in the spectrogram.
enum SpectrogramChannel {
    case input
    case output
    case difference
    case normalizedDifference
}

/// Renders a single scrolling waterfall spectrogram from FFT magnitude data.
///
/// Maintains a circular pixel buffer backed by a persistent CGBitmapContext.
/// New frequency columns are written at the cursor position, eliminating
/// the O(width*height) shift-left that the previous implementation required.
struct SpectrogramView: View {
    @ObservedObject var captureManager: AudioCaptureManager
    let channel: SpectrogramChannel
    var frequencyScale: FrequencyScale = .log
    var isPaused: Bool = false
    var isDivergingMap: Bool { channel == .difference || channel == .normalizedDifference }

    @State private var bitmapBuffer: SpectrogramBitmapBuffer?

    var body: some View {
        GeometryReader { geometry in
            let width = Int(geometry.size.width)
            let height = Int(geometry.size.height)

            Canvas { context, size in
                guard let buffer = bitmapBuffer, let fullImage = buffer.makeImage() else { return }
                let col = buffer.writeColumn

                if col == 0 {
                    // Buffer is in natural order — draw as single image
                    context.draw(
                        Image(fullImage, scale: 1, label: Text("")),
                        in: CGRect(origin: .zero, size: size)
                    )
                } else {
                    let bufW = buffer.width
                    let bufH = buffer.height
                    let leftColumnsCount = bufW - col  // older data: [col ..< bufW]
                    let rightColumnsCount = col         // newer data: [0 ..< col]

                    // Scale factors from pixel coords to view coords
                    let scaleX = size.width / CGFloat(bufW)
                    let scaleY = size.height / CGFloat(bufH)

                    // Left portion (older data) — from pixel column `col` to end
                    if leftColumnsCount > 0,
                       let leftCrop = fullImage.cropping(to: CGRect(
                           x: col, y: 0, width: leftColumnsCount, height: bufH
                       )) {
                        context.draw(
                            Image(leftCrop, scale: 1, label: Text("")),
                            in: CGRect(
                                x: 0,
                                y: 0,
                                width: CGFloat(leftColumnsCount) * scaleX,
                                height: size.height
                            )
                        )
                    }

                    // Right portion (newer data) — from pixel column 0 to `col`
                    if rightColumnsCount > 0,
                       let rightCrop = fullImage.cropping(to: CGRect(
                           x: 0, y: 0, width: rightColumnsCount, height: bufH
                       )) {
                        context.draw(
                            Image(rightCrop, scale: 1, label: Text("")),
                            in: CGRect(
                                x: CGFloat(leftColumnsCount) * scaleX,
                                y: 0,
                                width: CGFloat(rightColumnsCount) * scaleX,
                                height: size.height
                            )
                        )
                    }
                }
            }
            .onChange(of: captureManager.updateCounter) { _, _ in
                // Always drain to prevent unbounded accumulation,
                // but only append to the bitmap when not paused.
                if isPaused {
                    _ = captureManager.drainColumns(for: channel)
                } else {
                    ensureBuffer(width: width, height: height)
                    drainPendingColumns(height: height)
                }
            }
            .onChange(of: isPaused) { _, newValue in
                if !newValue {
                    // Clear the buffer on unpause so the spectrogram starts fresh
                    if width > 0 && height > 0 {
                        bitmapBuffer = SpectrogramBitmapBuffer(width: width, height: height)
                    }
                }
            }
            .onChange(of: geometry.size) { _, newSize in
                let w = Int(newSize.width)
                let h = Int(newSize.height)
                if w > 0 && h > 0 {
                    bitmapBuffer = SpectrogramBitmapBuffer(width: w, height: h)
                }
            }
            .onAppear {
                if width > 0 && height > 0 {
                    bitmapBuffer = SpectrogramBitmapBuffer(width: width, height: height)
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
        case .normalizedDifference: return "normalizedDifference"
        }
    }

    /// Drain all pending columns for this channel, appending each as a
    /// spectrogram column. This ensures no FFT windows are lost when
    /// display link callbacks are delayed (e.g. during slider drags).
    private func drainPendingColumns(height: Int) {
        let columns = captureManager.drainColumns(for: channel)
        for mags in columns {
            if !mags.isEmpty {
                appendColumn(magnitudes: mags, height: height)
            }
        }
    }

    private func ensureBuffer(width: Int, height: Int) {
        if bitmapBuffer == nil && width > 0 && height > 0 {
            bitmapBuffer = SpectrogramBitmapBuffer(width: width, height: height)
        }
    }

    private func appendColumn(magnitudes: [Float], height: Int) {
        guard let buffer = bitmapBuffer else { return }
        let binCount = magnitudes.count
        guard binCount > 0 && height > 0 else { return }

        // Build a column of pixels (bottom to top: index 0 = lowest frequency)
        var column = [SIMD4<UInt8>](repeating: .zero, count: height)

        for y in 0..<height {
            // Map pixel y (0 = bottom) to FFT bin using frequency scale
            let normalizedY = Float(y) / Float(height)

            // Inverse map from display position to frequency bin
            let bin = inverseBinMapping(displayPos: normalizedY, binCount: binCount)
            let binIndex = min(max(Int(bin), 0), binCount - 1)

            let value = magnitudes[binIndex]

            if channel == .normalizedDifference {
                column[y] = SpectrogramColorMap.divergingForDB(value, range: 1.0)
            } else if isDivergingMap {
                column[y] = SpectrogramColorMap.divergingForDB(value, range: 40.0)
            } else {
                column[y] = SpectrogramColorMap.magmaForDB(value, floor: AudioCaptureManager.floorDB)
            }
        }

        buffer.appendColumn(column)
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

// MARK: - Bitmap Buffer

/// A persistent CGBitmapContext-backed circular buffer for waterfall spectrogram rendering.
///
/// Instead of shifting all pixels left on each new column (O(width*height)),
/// maintains a write cursor that advances circularly. New columns overwrite
/// at the cursor position. The Canvas renders two cropped halves to present
/// the circular buffer in the correct visual order.
final class SpectrogramBitmapBuffer {
    let width: Int
    let height: Int
    /// Next column index to write. After writing, this advances by 1 (wrapping).
    /// The visual order is: columns [writeColumn ..< width] (older), then [0 ..< writeColumn] (newer).
    private(set) var writeColumn: Int = 0

    private let context: CGContext
    private let baseAddress: UnsafeMutablePointer<UInt8>
    private let bytesPerRow: Int

    init?(width: Int, height: Int, fillColor: SIMD4<UInt8> = SIMD4<UInt8>(0, 0, 0, 255)) {
        guard width > 0 && height > 0 else { return nil }
        self.width = width
        self.height = height

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        // Let CGContext allocate optimally aligned memory (data: nil, bytesPerRow: 0)
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

        // Fill with the specified color
        let totalBytes = bytesPerRow * height
        for i in stride(from: 0, to: totalBytes, by: 4) {
            baseAddress[i] = fillColor.x     // R
            baseAddress[i + 1] = fillColor.y // G
            baseAddress[i + 2] = fillColor.z // B
            baseAddress[i + 3] = fillColor.w // A
        }
    }

    /// Write a column of pixels at the current cursor position and advance.
    /// `column` has `height` entries where index 0 = bottom (lowest frequency).
    /// The bitmap stores y=0 at top (CGImage orientation), so we flip during write.
    func appendColumn(_ column: [SIMD4<UInt8>]) {
        guard column.count == height else { return }

        let col = writeColumn
        for y in 0..<height {
            // column[y] is bottom-to-top; bitmap row 0 is top
            let row = height - 1 - y
            let offset = row * bytesPerRow + col * 4
            let pixel = column[y]
            baseAddress[offset] = pixel.x       // R
            baseAddress[offset + 1] = pixel.y   // G
            baseAddress[offset + 2] = pixel.z   // B
            baseAddress[offset + 3] = pixel.w   // A
        }

        writeColumn = (col + 1) % width
    }

    /// Create a CGImage snapshot from the persistent bitmap context.
    /// Per Apple docs, CGContext.makeImage() returns an immutable image —
    /// CG manages the copy internally. Thread safety is guaranteed because
    /// both appendColumn() and Canvas rendering run on the main thread
    /// (via CADisplayLink → onChange → Canvas), so they never overlap.
    func makeImage() -> CGImage? {
        context.makeImage()
    }
}
