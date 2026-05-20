import Foundation
#if canImport(CImageDecodeBridge)
import CImageDecodeBridge
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(ImageIO)
import ImageIO
#endif

/// Errors raised by `ImageDecoder.decode(...)`.
public enum ImageDecodeError: Error, CustomStringConvertible {
    /// File at the given URL does not exist or cannot be read.
    case fileNotFound(URL)
    /// The format is not supported on this platform / in this build.
    case unsupportedFormat(String)
    /// The decoder reached the data but could not produce a valid image.
    case decodeFailure(String)

    public var description: String {
        switch self {
        case .fileNotFound(let url):       return "image file not found: \(url.path)"
        case .unsupportedFormat(let s):    return "unsupported image format: \(s)"
        case .decodeFailure(let s):        return "image decode failure: \(s)"
        }
    }
}

/// Raw RGBA8 bitmap with straight (non-premultiplied) alpha. Width/height
/// are in pixels; `pixels.count == width * height * 4`. The byte order is
/// `[R, G, B, A]`, top-left origin, which matches what
/// `DrawListRenderer.registerColorTexture(...)` expects.
public struct DecodedImage: Sendable {
    public let pixels: [UInt8]
    public let width: Int
    public let height: Int

    public init(pixels: [UInt8], width: Int, height: Int) {
        self.pixels = pixels
        self.width = width
        self.height = height
    }
}

/// File → RGBA decoder. Bitmap formats (PNG/JPEG/GIF/HEIC/BMP/TIFF) flow
/// PNG/JPEG/WebP/SVG flow through the cross-platform native bridge; Apple-only
/// formats such as PDF keep using the ImageIO/AppKit fallback.
///
/// The renderer uses straight-alpha blending (`srcAlpha * src + (1-srcAlpha) * dst`),
/// so this decoder un-premultiplies the bytes that CoreGraphics produces.
public enum ImageDecoder {

    /// Decode an image file into raw RGBA8.
    ///
    /// - Parameters:
    ///   - url: Source file. Format is inferred from contents (bitmap) or
    ///          file extension (`.svg`, `.pdf` → vector).
    ///   - targetSize: Optional explicit size in pixels. **Required** for
    ///                 vector formats (SVG/PDF). For bitmap formats it
    ///                 forces a resample (CoreGraphics high-quality);
    ///                 omit to keep the source resolution.
    public static func decode(url: URL,
                              targetSize: (width: Int, height: Int)? = nil) throws -> DecodedImage {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            throw ImageDecodeError.fileNotFound(url)
        }
        let ext = url.pathExtension.lowercased()
        #if canImport(CImageDecodeBridge)
        if Self.nativeSupportedExtensions.contains(ext) {
            return try decodeNative(url: url, extension: ext, targetSize: targetSize)
        }
        #endif

        #if canImport(AppKit) && canImport(CoreGraphics) && canImport(ImageIO)
        if ext == "pdf" {
            return try decodeVector(url: url, targetSize: targetSize)
        }
        return try decodeBitmap(url: url, targetSize: targetSize)
        #else
        throw ImageDecodeError.unsupportedFormat(ext.isEmpty ? "<unknown>" : ext)
        #endif
    }

    /// Decode raw in-memory bytes (e.g. PNG bytes loaded from a bundle).
    /// Bitmap formats only — pass `targetSize` to resample.
    public static func decode(data: Data,
                              targetSize: (width: Int, height: Int)? = nil) throws -> DecodedImage {
        #if canImport(CoreGraphics) && canImport(ImageIO)
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw ImageDecodeError.decodeFailure("CGImageSource: cannot decode \(data.count) bytes")
        }
        return rasterize(cg, targetSize: targetSize)
        #else
        throw ImageDecodeError.unsupportedFormat("data decode requires CoreGraphics")
        #endif
    }

    #if canImport(CImageDecodeBridge)

    private static let nativeSupportedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "webp", "svg"
    ]

    private static func decodeNative(url: URL,
                                     extension ext: String,
                                     targetSize: (Int, Int)?) throws -> DecodedImage {
        let data = try Data(contentsOf: url)
        var result = GuavaImageDecodeResult()
        let ok = data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return false
            }
            return ext.withCString { extCString in
                guava_image_decode_memory(
                    base,
                    data.count,
                    extCString,
                    Int32(targetSize?.0 ?? 0),
                    Int32(targetSize?.1 ?? 0),
                    &result
                )
            }
        }
        defer { guava_image_decode_free(&result) }
        guard ok, let pixels = result.pixels, result.width > 0, result.height > 0 else {
            let message = result.error_message.map { String(cString: $0) } ?? "native image decoder failed"
            throw ImageDecodeError.decodeFailure("\(url.lastPathComponent): \(message)")
        }
        let byteCount = Int(result.width) * Int(result.height) * 4
        let buffer = UnsafeBufferPointer(start: pixels, count: byteCount)
        return DecodedImage(pixels: Array(buffer),
                            width: Int(result.width),
                            height: Int(result.height))
    }

    #endif

    #if canImport(AppKit) && canImport(CoreGraphics) && canImport(ImageIO)

    private static func decodeBitmap(url: URL,
                                     targetSize: (Int, Int)?) throws -> DecodedImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw ImageDecodeError.decodeFailure("CGImageSource: cannot decode \(url.path)")
        }
        return rasterize(cg, targetSize: targetSize)
    }

    private static func decodeVector(url: URL,
                                     targetSize: (Int, Int)?) throws -> DecodedImage {
        guard let nsImage = NSImage(contentsOf: url) else {
            throw ImageDecodeError.decodeFailure("NSImage: cannot load \(url.path)")
        }
        // Vector images may report a zero size — fall back to a sensible
        // default and require the caller to pass `targetSize` for crisp
        // rasterisation.
        let intrinsic = nsImage.size
        let defaultW = intrinsic.width  > 0 ? Int(intrinsic.width.rounded())  : 64
        let defaultH = intrinsic.height > 0 ? Int(intrinsic.height.rounded()) : 64
        let w = targetSize?.0 ?? defaultW
        let h = targetSize?.1 ?? defaultH
        guard w > 0, h > 0 else {
            throw ImageDecodeError.decodeFailure("zero target size for \(url.lastPathComponent)")
        }
        var rect = CGRect(x: 0, y: 0, width: w, height: h)
        guard let cg = nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            throw ImageDecodeError.decodeFailure("NSImage.cgImage failed for \(url.path)")
        }
        return rasterize(cg, targetSize: (w, h))
    }

    /// Draw a `CGImage` into a normalized RGBA8 buffer at the requested size,
    /// then un-premultiply so the resulting bytes match the renderer's
    /// straight-alpha blend convention.
    private static func rasterize(_ cg: CGImage,
                                  targetSize: (Int, Int)?) -> DecodedImage {
        let w = targetSize?.0 ?? cg.width
        let h = targetSize?.1 ?? cg.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedLast.rawValue
                               | CGBitmapInfo.byteOrder32Big.rawValue
        bytes.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress,
                  let ctx = CGContext(data: base,
                                      width: w, height: h,
                                      bitsPerComponent: 8,
                                      bytesPerRow: w * 4,
                                      space: cs,
                                      bitmapInfo: bitmapInfo) else { return }
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        unpremultiplyInPlace(&bytes)
        return DecodedImage(pixels: bytes, width: w, height: h)
    }

    /// CoreGraphics writes premultiplied RGBA. The renderer's alpha blend
    /// state expects straight RGBA, so divide each colour channel by alpha.
    private static func unpremultiplyInPlace(_ bytes: inout [UInt8]) {
        let count = bytes.count
        var i = 0
        while i + 3 < count {
            let a = bytes[i + 3]
            if a != 0 && a != 255 {
                let af = Float(a)
                bytes[i + 0] = UInt8(min(255, (Float(bytes[i + 0]) * 255.0 / af).rounded()))
                bytes[i + 1] = UInt8(min(255, (Float(bytes[i + 1]) * 255.0 / af).rounded()))
                bytes[i + 2] = UInt8(min(255, (Float(bytes[i + 2]) * 255.0 / af).rounded()))
            } else if a == 0 {
                // Discard residual colour for fully-transparent pixels so
                // bilinear sampling near edges doesn't bleed garbage.
                bytes[i + 0] = 0
                bytes[i + 1] = 0
                bytes[i + 2] = 0
            }
            i += 4
        }
    }

    #endif // AppKit + CoreGraphics + ImageIO
}
