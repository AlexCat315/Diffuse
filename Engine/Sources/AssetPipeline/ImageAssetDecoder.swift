import Foundation
// The C bridge is an internal detail (its types never appear in AssetPipeline's
// API), so consumers/tests that import AssetPipeline don't need the C module in
// their own import path.
internal import CImageDecodeBridge

public struct DecodedTextureAsset: Sendable, Equatable {
    public var pixels: [UInt8]
    public var width: Int
    public var height: Int

    public init(pixels: [UInt8], width: Int, height: Int) {
        self.pixels = pixels
        self.width = width
        self.height = height
    }
}

public enum ImageAssetDecoderError: Error, CustomStringConvertible {
    case sourceUnreadable(String)
    case imageMissing(String)
    case invalidDimensions(String)
    case decodeFailed(String)

    public var description: String {
        switch self {
        case let .sourceUnreadable(path): return "image source unreadable: \(path)"
        case let .imageMissing(path): return "image missing first frame: \(path)"
        case let .invalidDimensions(path): return "image has invalid dimensions: \(path)"
        case let .decodeFailed(msg): return "image decode failed: \(msg)"
        }
    }
}

/// Decodes image files into straight-alpha RGBA8 via the cross-platform native
/// bridge (stb_image for png/jpg/bmp/gif/tga, libwebp for webp, lunasvg for
/// svg). One code path on every platform — no Apple ImageIO special-case.
public enum ImageAssetDecoder {
    public static func decodeRGBA8(path: String) throws -> DecodedTextureAsset {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url) else {
            throw ImageAssetDecoderError.sourceUnreadable(path)
        }
        return try decode(data: data, extension: url.pathExtension, label: path)
    }

    public static func decodeRGBA8(data: Data, label: String = "<memory>") throws -> DecodedTextureAsset {
        // Extension is unknown for raw bytes; the bridge sniffs the format.
        try decode(data: data, extension: "", label: label)
    }

    private static func decode(data: Data, extension ext: String, label: String) throws -> DecodedTextureAsset {
        guard !data.isEmpty else { throw ImageAssetDecoderError.sourceUnreadable(label) }

        var result = GuavaImageDecodeResult()
        let ok = data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
            return ext.withCString { extC in
                guava_image_decode_memory(base, data.count, extC, 0, 0, &result)
            }
        }
        defer { guava_image_decode_free(&result) }

        guard ok, let pixels = result.pixels else {
            let message = result.error_message.map { String(cString: $0) } ?? "native image decoder failed"
            throw ImageAssetDecoderError.decodeFailed("\(label): \(message)")
        }
        guard result.width > 0, result.height > 0 else {
            throw ImageAssetDecoderError.invalidDimensions(label)
        }
        let byteCount = Int(result.width) * Int(result.height) * 4
        return DecodedTextureAsset(pixels: Array(UnsafeBufferPointer(start: pixels, count: byteCount)),
                                   width: Int(result.width),
                                   height: Int(result.height))
    }
}
