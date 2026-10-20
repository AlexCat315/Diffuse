import Foundation
import Testing
@testable import GuavaUIRuntime
#if canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@Suite("Progressive image previews")
struct ProgressiveImageTests {
    @Test("An incomplete progressive JPEG produces an aspect-preserving preview with real pixels")
    func incompleteJPEG() throws {
        let data = try jpeg()
        let bytes = [UInt8](data)
        let scans = bytes.indices.dropLast().filter { bytes[$0] == 0xFF && bytes[$0 + 1] == 0xDA }
        #expect(scans.count > 2)
        let partial = data.prefix(try #require(scans.dropFirst().first))
        #expect(partial.count < data.count)
        let image = try #require(ImageDecoder.decodePartial(data: partial, boundingSize: (96, 96)))
        #expect(image.width == 96 && image.height == 48)
        let left = (24 * image.width + 10) * 4, right = (24 * image.width + 85) * 4
        #expect(Int(image.pixels[left]) > Int(image.pixels[left + 1]) + 100)
        #expect(Int(image.pixels[right + 1]) > Int(image.pixels[right]) + 100)
        #expect(image.pixels[left + 3] == 255 && image.pixels[right + 3] == 255)
    }

    @Test("Preview geometry follows EXIF orientation and never upscales")
    func orientationAndBounds() throws {
        let data = try jpeg(orientation: 6)
        let upright = try #require(ImageDecoder.decodePartial(data: data, boundingSize: (96, 96)))
        #expect(upright.width == 48 && upright.height == 96)
        let original = try #require(ImageDecoder.decodePartial(data: data, boundingSize: (512, 512)))
        #expect(original.width == 128 && original.height == 256)
    }

    @Test("Preview allocation obeys source pixels and bounded target dimensions")
    func limits() throws {
        let data = try jpeg()
        #expect(ImageDecoder.decodePartial(data: data, boundingSize: (32, 32), maximumSourcePixels: 256 * 128 - 1) == nil)
        #expect(ImageDecoder.decodePartial(data: data, boundingSize: (32, 32), maximumSourcePixels: 0) == nil)
        for width in [-1, 0, 8_193, Int.max] {
            #expect(ImageDecoder.decodePartial(data: data, boundingSize: (width, 32)) == nil)
        }
        #expect(ImageDecoder.decodePartial(data: Data(), boundingSize: (32, 32)) == nil)
        #expect(ImageDecoder.decodePartial(data: data.prefix(32), boundingSize: (32, 32)) == nil)
    }

    private func jpeg(orientation: Int = 1) throws -> Data {
        let width = 256, height = 128
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let start = (y * width + x) * 4, noise = UInt8((x * 73 + y * 31) % 32)
            pixels[start] = x < width / 2 ? 220 + noise : noise
            pixels[start + 1] = x < width / 2 ? noise : 220 + noise
            pixels[start + 2] = noise
        } }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyJFIFDictionary: [kCGImagePropertyJFIFIsProgressive: true],
            kCGImagePropertyOrientation: orientation,
            kCGImageDestinationLossyCompressionQuality: 0.85,
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
#endif
