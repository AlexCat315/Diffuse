import Foundation
#if canImport(ImageIO) && canImport(CoreGraphics)
import CoreGraphics
import ImageIO
#endif

public extension ImageDecoder {
    /// Best-effort preview from a prefix of a progressive JPEG or interlaced
    /// PNG, fitted inside `boundingSize`. Uses ImageIO's incremental source
    /// where available; other platforms return `nil` and show the final image
    /// only. The preview is never cached.
    static func decodePartial(data: Data, boundingSize: (width: Int, height: Int),
                              maximumSourcePixels: Int = 32_000_000) -> DecodedImage? {
        #if canImport(CoreGraphics) && canImport(ImageIO)
        guard !data.isEmpty, (1...8_192).contains(boundingSize.width), (1...8_192).contains(boundingSize.height),
              maximumSourcePixels > 0 else { return nil }
        let source = CGImageSourceCreateIncremental(nil)
        CGImageSourceUpdateData(source, data as CFData, false)
        guard CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusIncomplete || CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width.isFinite, height.isFinite, width > 0, height > 0,
              width * height <= Double(maximumSourcePixels) else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let upright = ImageOrientation.swapsAxes(orientation) ? (height, width) : (width, height)
        let fit = min(1, min(Double(boundingSize.width) / upright.0, Double(boundingSize.height) / upright.1))
        let target = (max(1, Int((upright.0 * fit).rounded())), max(1, Int((upright.1 * fit).rounded())))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(target.0, target.1),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return rasterize(image, targetSize: target)
        #else
        return nil
        #endif
    }
}
