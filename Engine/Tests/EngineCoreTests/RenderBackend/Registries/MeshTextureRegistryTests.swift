// Fixtures are generated with CoreGraphics/ImageIO (Apple-only). Guarded until
// image decoding is portable (stb_image); see ImageAssetDecoder.
#if canImport(CoreGraphics)
import AssetPipeline
import CoreGraphics
import Foundation
import ImageIO
@testable import RenderBackend
import Testing
import UniformTypeIdentifiers

@Suite("MeshTextureRegistry", .serialized)
struct MeshTextureRegistryTests {
    @Test("decodes mesh textures into render texture cache")
    func decodesMeshTextures() throws {
        let registry = MeshTextureRegistry.shared
        registry.clearAll()
        defer { registry.clearAll() }

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let textureURL = tempRoot.appendingPathComponent("hero_ink.png")
        try writePNG(url: textureURL,
                     pixels: [
                        21, 22, 23, 255,
                        31, 32, 33, 255,
                     ],
                     width: 2,
                     height: 1)

        let mesh = MeshAsset(
            name: "hero",
            vertices: [],
            indices: [],
            textures: [MeshTexture(sourceURI: "hero_ink.png", mimeType: "image/png")]
        )

        let report = registry.register(meshIndex: 12,
                                       mesh: mesh,
                                       sourceDirectory: tempRoot.path)

        #expect(report.failures.isEmpty)
        #expect(report.decodedTextures.map(\ .textureIndex) == [0])
        #expect(report.decodedTextures.first?.sourcePath == textureURL.path)
        #expect(report.decodedTextures.first?.texture.pixels == [
            21, 22, 23, 255,
            31, 32, 33, 255,
        ])
        #expect(registry.textures(for: 12) == report)
    }

    @Test("records mesh texture decode failures without dropping the report")
    func recordsDecodeFailures() {
        let registry = MeshTextureRegistry.shared
        registry.clearAll()
        defer { registry.clearAll() }

        let mesh = MeshAsset(
            name: "hero",
            vertices: [],
            indices: [],
            textures: [MeshTexture(sourceURI: "missing.png", mimeType: "image/png")]
        )

        let report = registry.register(meshIndex: 13,
                                       mesh: mesh,
                                       sourceDirectory: nil)

        #expect(report.decodedTextures.isEmpty)
        #expect(report.failures.count == 1)
        #expect(report.failures.first?.textureIndex == 0)
        #expect(report.failures.first?.sourceURI == "missing.png")
        #expect(registry.textures(for: 13) == report)
    }

    private func writePNG(url: URL, pixels: [UInt8], width: Int, height: Int) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bitsPerPixel: 32,
                                  bytesPerRow: width * 4,
                                  space: colorSpace,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                                  provider: provider,
                                  decode: nil,
                                  shouldInterpolate: false,
                                  intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                                UTType.png.identifier as CFString,
                                                                1,
                                                                nil)
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        if !CGImageDestinationFinalize(destination) {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
#endif
