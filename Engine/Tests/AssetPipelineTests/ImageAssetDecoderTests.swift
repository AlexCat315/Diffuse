import AssetPipeline
import Foundation
import Testing

@Suite("ImageAssetDecoder")
struct ImageAssetDecoderTests {
    @Test("decodes png into rgba8 pixels")
    func decodesPNG() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let url = tempRoot.appendingPathComponent("texture.png")
        try writePNG(url: url,
                     pixels: [
                        255, 0, 0, 255,
                        0, 255, 0, 255,
                     ],
                     width: 2,
                     height: 1)

        let decoded = try ImageAssetDecoder.decodeRGBA8(path: url.path)

        #expect(decoded.width == 2)
        #expect(decoded.height == 1)
        #expect(decoded.pixels == [
            255, 0, 0, 255,
            0, 255, 0, 255,
        ])
    }

    @Test("decodes in-memory png into rgba8 pixels")
    func decodesInMemoryPNG() throws {
        let data = try makePNGData(pixels: [
            2, 4, 6, 255,
            8, 10, 12, 255,
        ], width: 2, height: 1)

        let decoded = try ImageAssetDecoder.decodeRGBA8(data: data, label: "memory.png")

        #expect(decoded.width == 2)
        #expect(decoded.height == 1)
        #expect(decoded.pixels == [
            2, 4, 6, 255,
            8, 10, 12, 255,
        ])
    }

    @Test("resolves and decodes relative mesh texture uri")
    func resolvesRelativeMeshTextureURI() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let textureURL = tempRoot.appendingPathComponent("hero_base.png")
        try writePNG(url: textureURL,
                     pixels: [
                        12, 34, 56, 255,
                        78, 90, 123, 255,
                     ],
                     width: 2,
                     height: 1)

        let texture = MeshTexture(sourceURI: "hero_base.png", mimeType: "image/png")
        let resolved = try MeshTextureResolver.decode(texture, sourceDirectory: tempRoot.path)

        #expect(resolved.path == textureURL.path)
        #expect(resolved.texture.width == 2)
        #expect(resolved.texture.height == 1)
        #expect(resolved.texture.pixels == [
            12, 34, 56, 255,
            78, 90, 123, 255,
        ])
    }

    @Test("rejects embedded mesh texture uri until buffer image import is implemented")
    func rejectsEmbeddedMeshTextureURI() throws {
        let texture = MeshTexture(sourceURI: "data:image/png;base64,AAAA", mimeType: "image/png")

        #expect(throws: MeshTextureResolverError.unsupportedEmbeddedURI("data:image/png;base64,AAAA")) {
            _ = try MeshTextureResolver.resolvePath(for: texture, sourceDirectory: "/tmp")
        }
    }

    @Test("decodes base64 data uri mesh texture")
    func decodesBase64DataURITexture() throws {
        let data = try makePNGData(pixels: [
            21, 22, 23, 255,
        ], width: 1, height: 1)
        let uri = "data:image/png;base64,\(data.base64EncodedString())"
        let resolved = try MeshTextureResolver.decode(
            MeshTexture(sourceURI: uri, mimeType: "image/png"),
            sourceDirectory: nil
        )

        #expect(resolved.path == uri)
        #expect(resolved.texture.width == 1)
        #expect(resolved.texture.height == 1)
        #expect(resolved.texture.pixels == [21, 22, 23, 255])
    }

    @Test("decodes embedded mesh texture data")
    func decodesEmbeddedTextureData() throws {
        let data = try makePNGData(pixels: [
            31, 32, 33, 255,
        ], width: 1, height: 1)
        let texture = MeshTexture(name: "embedded-base", mimeType: "image/png", data: data)

        let resolved = try MeshTextureResolver.decode(texture, sourceDirectory: nil)

        #expect(resolved.path == "embedded-base")
        #expect(resolved.texture.pixels == [31, 32, 33, 255])
    }

    private func writePNG(url: URL, pixels: [UInt8], width: Int, height: Int) throws {
        let data = try makePNGData(pixels: pixels, width: width, height: height)
        try data.write(to: url)
    }

    private func makePNGData(pixels: [UInt8], width: Int, height: Int) throws -> Data {
        PortablePNG.encode(pixels: pixels, width: width, height: height)
    }
}
