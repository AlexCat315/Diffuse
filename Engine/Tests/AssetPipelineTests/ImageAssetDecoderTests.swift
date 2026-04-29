import AssetPipeline
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

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
