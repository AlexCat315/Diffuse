import CoreGraphics
import Foundation
import ImageIO

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
    case contextCreationFailed(String)

    public var description: String {
        switch self {
        case let .sourceUnreadable(path):
            return "image source unreadable: \(path)"
        case let .imageMissing(path):
            return "image missing first frame: \(path)"
        case let .invalidDimensions(path):
            return "image has invalid dimensions: \(path)"
        case let .contextCreationFailed(path):
            return "rgba context creation failed: \(path)"
        }
    }
}

public enum ImageAssetDecoder {
    public static func decodeRGBA8(path: String) throws -> DecodedTextureAsset {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImageAssetDecoderError.sourceUnreadable(path)
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImageAssetDecoderError.imageMissing(path)
        }

        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else {
            throw ImageAssetDecoderError.invalidDimensions(path)
        }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw ImageAssetDecoderError.contextCreationFailed(path)
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return DecodedTextureAsset(pixels: pixels, width: width, height: height)
    }
}
