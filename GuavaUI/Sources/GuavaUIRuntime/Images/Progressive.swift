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
    static func decodePartial(data: Data, boundingSize: (width: Int, height: Int)) -> DecodedImage? {
        #if canImport(AppKit) && canImport(CoreGraphics) && canImport(ImageIO)
        guard data.count > 1_024, boundingSize.width > 0, boundingSize.height > 0 else { return nil }
        let source = CGImageSourceCreateIncremental(nil)
        CGImageSourceUpdateData(source, data as CFData, false)
        guard CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusIncomplete || CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width > 0, image.height > 0 else { return nil }
        let fit = min(1, min(Double(boundingSize.width) / Double(image.width), Double(boundingSize.height) / Double(image.height)))
        return rasterize(image, targetSize: (max(1, Int((Double(image.width) * fit).rounded())),
                                             max(1, Int((Double(image.height) * fit).rounded()))))
        #else
        return nil
        #endif
    }
}
