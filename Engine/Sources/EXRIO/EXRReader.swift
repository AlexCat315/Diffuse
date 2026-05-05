import COpenEXRBridge
import Foundation

public final class EXRReader: @unchecked Sendable {
    public struct LayerInfo: Sendable {
        public let name: String
        public let channels: [String]
    }

    private var context: GuavaEXRContext?
    public let path: String

    public init(path: String) throws {
        self.path = path
        guard let ctx = guava_exr_reader_open(path) else {
            throw EXRReaderError.openFailed(path)
        }
        self.context = ctx
    }

    deinit {
        if let context {
            guava_exr_reader_close(context)
        }
    }

    public var width: Int {
        guard let ctx = context else { return 0 }
        return Int(guava_exr_reader_get_width(ctx))
    }

    public var height: Int {
        guard let ctx = context else { return 0 }
        return Int(guava_exr_reader_get_height(ctx))
    }

    public var layerCount: Int {
        guard let ctx = context else { return 0 }
        return Int(guava_exr_reader_get_layer_count(ctx))
    }

    public func layerInfo(at index: Int) -> LayerInfo? {
        guard let ctx = context else { return nil }
        var desc = GuavaEXRLayerDesc(name: nil, channels: nil, channel_count: 0)
        guard guava_exr_reader_get_layer_desc(ctx, Int32(index), &desc) else { return nil }
        let name = desc.name.map { String(cString: $0) } ?? ""
        let channels = desc.channels.map { String(cString: $0).components(separatedBy: ",") } ?? []
        return LayerInfo(name: name, channels: channels)
    }

    public func readPixels(layerName: String) -> [Float] {
        guard let ctx = context else { return [] }
        let pixelCount = width * height * 4
        var pixels = [Float](repeating: 0, count: pixelCount)
        guard guava_exr_reader_read_layer_pixels(
            ctx,
            (layerName as NSString).utf8String,
            &pixels,
            Int32(pixelCount)
        ) else {
            return []
        }
        return pixels
    }
}

public enum EXRReaderError: Error {
    case openFailed(String)
}
