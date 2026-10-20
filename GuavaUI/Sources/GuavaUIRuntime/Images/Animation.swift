import Foundation
import CImageDecodeBridge

/// Frames of an animated GIF or WebP, already composited and scaled to the
/// requested thumbnail size. Durations follow browser practice: a frame that
/// asks for 10 ms or less is shown for 100 ms.
public struct DecodedAnimation: Sendable {
    public let frames: [DecodedImage]
    /// Seconds per frame.
    public let durations: [Double]
    /// 0 repeats forever.
    public let loopCount: Int
    public var totalDuration: Double { durations.reduce(0, +) }
}

public extension ImageDecoder {
    /// Animated frames for GIF/WebP data, or `nil` for still images and other
    /// formats. Frames are bounded by `boundingSize` (never upscaled), the
    /// source pixel budget and `maximumFrames`.
    static func decodeAnimation(data: Data, formatHint: String,
                                boundingSize: (width: Int, height: Int),
                                maximumSourcePixels: Int = 32_000_000,
                                maximumFrames: Int = 300) throws -> DecodedAnimation? {
        guard isAnimatable(data: data, formatHint: formatHint) else { return nil }
        var width: Int32 = 0, height: Int32 = 0
        let valid = data.withUnsafeBytes { buffer in
            formatHint.withCString { hint in
                guava_image_dimensions_memory(buffer.bindMemory(to: UInt8.self).baseAddress, data.count, hint, &width, &height)
            }
        }
        guard valid, width > 0, height > 0, Int64(width) * Int64(height) <= Int64(maximumSourcePixels) else {
            throw ImageDecodeError.decodeFailure("Invalid or oversized animation dimensions")
        }
        let fit = min(1, min(Double(boundingSize.width) / Double(width), Double(boundingSize.height) / Double(height)))
        let target = (max(1, Int((Double(width) * fit).rounded())), max(1, Int((Double(height) * fit).rounded())))
        // Keep every frame together under the same budget as one still image.
        let frameBudget = max(1, min(maximumFrames, maximumSourcePixels / max(1, target.0 * target.1)))
        var result = GuavaImageAnimationResult()
        let ok = data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
            return formatHint.withCString {
                guava_image_decode_animation_memory(base, data.count, $0, Int32(target.0), Int32(target.1),
                                                    Int32(frameBudget), &result)
            }
        }
        defer { guava_image_animation_free(&result) }
        guard ok, let pixels = result.pixels, let durations = result.durations_ms else {
            let message = result.error_message.map { String(cString: $0) } ?? "animation decoder failed"
            throw ImageDecodeError.decodeFailure(message)
        }
        let count = Int(result.frame_count)
        guard count > 1 else { return nil }
        let frameBytes = Int(result.width) * Int(result.height) * 4
        let frames = (0..<count).map { index in
            DecodedImage(pixels: Array(UnsafeBufferPointer(start: pixels + index * frameBytes, count: frameBytes)),
                         width: Int(result.width), height: Int(result.height))
        }
        let seconds = (0..<count).map { index -> Double in
            let milliseconds = Int(durations[index])
            return Double(milliseconds <= 10 ? 100 : milliseconds) / 1_000
        }
        return DecodedAnimation(frames: frames, durations: seconds, loopCount: Int(result.loop_count))
    }

    /// GIF, or WebP whose VP8X header carries the animation flag.
    static func isAnimatable(data: Data, formatHint: String) -> Bool {
        let bytes = [UInt8](data.prefix(32))
        if bytes.count >= 4, bytes[0...3].elementsEqual([0x47, 0x49, 0x46, 0x38]) { return true }
        guard bytes.count >= 21, bytes[0...3].elementsEqual([0x52, 0x49, 0x46, 0x46]), bytes[8...11].elementsEqual([0x57, 0x45, 0x42, 0x50]),
              bytes[12...15].elementsEqual([0x56, 0x50, 0x38, 0x58]) else { return false }
        return bytes[20] & 0x02 != 0
    }
}
