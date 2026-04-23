import Foundation
import Testing
#if canImport(AppKit)
import AppKit
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(ImageIO)
import ImageIO
import UniformTypeIdentifiers
#endif
@testable import GuavaUIRuntime

/// Coverage for `ImageDecoder` — bitmap (PNG) round-trip plus error
/// surface for missing files and unsupported sources.
@Suite("ImageDecoder")
struct ImageDecoderTests {

    /// Encode a 4×3 RGBA8 buffer to a temporary PNG, decode it back via
    /// `ImageDecoder.decode(url:)`, and verify the dimensions plus the
    /// straight-alpha pixel values survive the round trip.
    @Test("PNG round-trip preserves size and straight-alpha pixels")
    func pngRoundTrip() throws {
        #if canImport(AppKit) && canImport(ImageIO)
        let w = 4, h = 3
        // Build a deterministic RGBA buffer: column 0 is opaque red,
        // column 1 is opaque green, column 2 is opaque blue, column 3
        // is half-transparent yellow.
        var src = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                switch x {
                case 0: src[i] = 255; src[i+1] = 0;   src[i+2] = 0;   src[i+3] = 255
                case 1: src[i] = 0;   src[i+1] = 255; src[i+2] = 0;   src[i+3] = 255
                case 2: src[i] = 0;   src[i+1] = 0;   src[i+2] = 255; src[i+3] = 255
                default: src[i] = 255; src[i+1] = 255; src[i+2] = 0;  src[i+3] = 128
                }
            }
        }

        // Encode straight RGBA → PNG via ImageIO.
        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedLast.rawValue
                               | CGBitmapInfo.byteOrder32Big.rawValue
        // ImageIO writes whatever CoreGraphics gives it; we feed it a
        // premultiplied buffer (so the colours match the data we wrote
        // in straight-alpha form, since alpha is either 0/255/128 and
        // for the half-transparent cell we pre-premultiply manually).
        var encoded = src
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let a = encoded[i + 3]
                if a != 255 && a != 0 {
                    encoded[i + 0] = UInt8((Int(encoded[i + 0]) * Int(a)) / 255)
                    encoded[i + 1] = UInt8((Int(encoded[i + 1]) * Int(a)) / 255)
                    encoded[i + 2] = UInt8((Int(encoded[i + 2]) * Int(a)) / 255)
                }
            }
        }
        let provider = CGDataProvider(data: Data(encoded) as CFData)!
        let cg = CGImage(width: w, height: h,
                         bitsPerComponent: 8, bitsPerPixel: 32,
                         bytesPerRow: w * 4,
                         space: cs,
                         bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                         provider: provider,
                         decode: nil,
                         shouldInterpolate: false,
                         intent: .defaultIntent)!

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("guavaui-image-decoder-\(UUID().uuidString).png")
        let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                   UTType.png.identifier as CFString,
                                                   1, nil)!
        CGImageDestinationAddImage(dest, cg, nil)
        #expect(CGImageDestinationFinalize(dest))
        defer { try? FileManager.default.removeItem(at: url) }

        let decoded = try ImageDecoder.decode(url: url)
        #expect(decoded.width == w)
        #expect(decoded.height == h)
        #expect(decoded.pixels.count == w * h * 4)

        // Opaque red pixel survived intact.
        #expect(decoded.pixels[0] == 255)
        #expect(decoded.pixels[1] == 0)
        #expect(decoded.pixels[2] == 0)
        #expect(decoded.pixels[3] == 255)
        // Half-transparent yellow: alpha 128, colour un-premultiplied
        // back to ~(255, 255, 0). Allow ±2 for round-trip noise.
        let yellowIdx = (0 * w + 3) * 4
        #expect(decoded.pixels[yellowIdx + 3] == 128)
        #expect(abs(Int(decoded.pixels[yellowIdx + 0]) - 255) <= 2)
        #expect(abs(Int(decoded.pixels[yellowIdx + 1]) - 255) <= 2)
        #expect(decoded.pixels[yellowIdx + 2] <= 2)
        #endif
    }

    @Test("Missing file raises .fileNotFound")
    func missingFileRaises() {
        let url = URL(fileURLWithPath: "/tmp/this-file-should-not-exist-\(UUID().uuidString).png")
        do {
            _ = try ImageDecoder.decode(url: url)
            Issue.record("expected ImageDecodeError.fileNotFound")
        } catch ImageDecodeError.fileNotFound {
            // ok
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
