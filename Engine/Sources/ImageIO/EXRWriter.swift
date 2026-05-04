import COpenEXRBridge
import Foundation

public final class EXRWriter: @unchecked Sendable {
    public enum PixelType: Sendable {
        case half
        case float
    }

    public struct Layer: Sendable {
        public let name: String
        public let channels: [String]
        public let pixelType: PixelType

        public init(name: String, channels: [String], pixelType: PixelType = .half) {
            self.name = name
            self.channels = channels
            self.pixelType = pixelType
        }
    }

    private let path: String
    private let width: Int
    private let height: Int
    private var context: GuavaEXRContext?
    private var layers: [Layer] = []

    public init(path: String, width: Int, height: Int) {
        self.path = path
        self.width = width
        self.height = height
    }

    public func addLayer(_ layer: Layer) {
        layers.append(layer)
    }

    public func write() throws -> Bool {
        guard let ctx = guava_exr_writer_create(path, Int32(width), Int32(height)) else {
            throw EXRWriterError.contextCreationFailed
        }
        context = ctx
        defer { guava_exr_writer_destroy(ctx) }

        for layer in layers {
            var desc = GuavaEXRLayerDesc(
                name: (layer.name as NSString).utf8String,
                channels: (layer.channels.joined(separator: ",") as NSString).utf8String,
                channel_count: Int32(layer.channels.count)
            )
            let pixelType: GuavaEXRPixelType = layer.pixelType == .float
                ? GUAVA_EXR_FLOAT : GUAVA_EXR_HALF
            guard guava_exr_writer_add_layer(ctx, &desc, pixelType) else {
                throw EXRWriterError.layerCreationFailed(layer.name)
            }
        }

        return guava_exr_writer_write(ctx)
    }

    public func setPixels(_ pixels: [Float], for layerName: String) -> Bool {
        guard let ctx = context else { return false }
        return guava_exr_writer_set_layer_pixels(
            ctx,
            (layerName as NSString).utf8String,
            pixels,
            Int32(pixels.count)
        )
    }
}

public enum EXRWriterError: Error {
    case contextCreationFailed
    case layerCreationFailed(String)
}
