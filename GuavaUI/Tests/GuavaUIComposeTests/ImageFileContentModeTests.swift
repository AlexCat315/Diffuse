import Testing
import CoreGraphics
import Foundation
#if canImport(ImageIO)
import ImageIO
import UniformTypeIdentifiers
#endif
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Image+File content mode", .serialized)
struct ImageFileContentModeTests: GuavaUIComposeSerializedSuite {

    @Test("Image(file:, .fit) uses decoded size when registry is unavailable")
    func fitUsesDecodedSizeWithoutRegistry() throws { try GlobalTestLock.locked {
        #if canImport(ImageIO)
        let png = try makePNG(width: 200, height: 100)
        defer { try? FileManager.default.removeItem(at: png) }

        ImageAssetRegistryHolder.current = nil

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root:
            Image(file: png.path,
                  width: 100,
                  height: 100,
                  contentMode: .fit)
        )
        graph.computeLayout(width: 100, height: 100)

        let image = tree.root?.children.first
        let list = DrawList()
        image?.draw?(list, .zero)

        #expect(list.batches.first?.textureID == .none)
        #expect(list.vertices.count == 4)
        let xs = list.vertices.map(\.posX)
        let ys = list.vertices.map(\.posY)
        #expect(xs.min() == 0)
        #expect(xs.max() == 100)
        #expect(ys.min() == 25)
        #expect(ys.max() == 75)
        #endif
    } }

    @Test("Image(file:, .fill) uses decoded size when registry is unavailable")
    func fillUsesDecodedSizeWithoutRegistry() throws { try GlobalTestLock.locked {
        #if canImport(ImageIO)
        let png = try makePNG(width: 200, height: 100)
        defer { try? FileManager.default.removeItem(at: png) }

        ImageAssetRegistryHolder.current = nil

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root:
            Image(file: png.path,
                  width: 100,
                  height: 100,
                  contentMode: .fill)
        )
        graph.computeLayout(width: 100, height: 100)

        let image = tree.root?.children.first
        let list = DrawList()
        image?.draw?(list, .zero)

        #expect(list.batches.first?.textureID == .none)
        #expect(list.vertices.count == 4)
        let xs = list.vertices.map(\.posX)
        let ys = list.vertices.map(\.posY)
        #expect(xs.min() == -50)
        #expect(xs.max() == 150)
        #expect(ys.min() == 0)
        #expect(ys.max() == 100)
        #endif
    } }

    @Test("Image(file:) emits diagnostics for missing registry and decode failure")
    func emitsDiagnosticsWithoutRegistry() { GlobalTestLock.locked {
        var events: [ImageLoadDiagnostic] = []
        let previous = ImageLoadDiagnostics.onEvent
        ImageLoadDiagnostics.onEvent = { events.append($0) }
        defer { ImageLoadDiagnostics.onEvent = previous }

        ImageAssetRegistryHolder.current = nil

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root:
            Image(file: "/path/that/does/not/exist.png",
                  width: 32,
                  height: 32,
                  contentMode: .fit)
        )
        graph.computeLayout(width: 64, height: 64)

        #expect(events.count >= 1)
        #expect(events.contains { $0.reason == .missingRegistry })
    } }

    #if canImport(ImageIO)
    private func makePNG(width: Int, height: Int) throws -> URL {
        let bytes = [UInt8](repeating: 255, count: width * height * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                              | CGBitmapInfo.byteOrder32Big.rawValue)
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        guard let image = CGImage(width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bitsPerPixel: 32,
                                  bytesPerRow: width * 4,
                                  space: cs,
                                  bitmapInfo: info,
                                  provider: provider,
                                  decode: nil,
                                  shouldInterpolate: false,
                                  intent: .defaultIntent) else {
            throw NSError(domain: "ImageFileContentModeTests", code: 1)
        }

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("guavaui-image-file-\(UUID().uuidString).png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                                 UTType.png.identifier as CFString,
                                                                 1,
                                                                 nil) else {
            throw NSError(domain: "ImageFileContentModeTests", code: 2)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "ImageFileContentModeTests", code: 3)
        }
        return url
    }
    #endif
}
