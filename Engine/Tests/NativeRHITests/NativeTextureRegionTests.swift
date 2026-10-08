import Foundation
import XCTest
@testable import NativeRHI

final class NativeTextureRegionTests: XCTestCase {
    func testUploadBoundsRejectOverflowAndInvalidRows() throws {
        for (origin, size, pitch, capacity) in [
            (SIMD2(-1, 0), SIMD2(1, 1), 4, 4),
            (SIMD2(0, -1), SIMD2(1, 1), 4, 4),
            (SIMD2(Int.max, 0), SIMD2(1, 1), 4, 4),
            (SIMD2(4, 3), SIMD2(1, 1), 4, 4),
            (SIMD2(3, 2), SIMD2(2, 1), 8, 8),
            (SIMD2(0, 0), SIMD2(0, 1), 4, 4),
            (SIMD2(0, 0), SIMD2(1, 1), 3, 4),
            (SIMD2(0, 0), SIMD2(1, 2), Int.max - 3, Int.max),
            (SIMD2(1, 1), SIMD2(2, 2), 8, 15)
        ] {
            var region = TextureUploadRegion(width: size.x, height: size.y); region.origin = origin
            XCTAssertThrowsError(try rhiTextureUploadBytes(region: region, rowBytes: pitch, format: .rgba8Unorm,
                textureWidth: 4, textureHeight: 3, capacity: capacity))
        }
        var edge = TextureUploadRegion(width: 1, height: 1); edge.origin = SIMD2(3, 2)
        XCTAssertEqual(try rhiTextureUploadBytes(region: edge, rowBytes: 8, format: .rgba8Unorm,
            textureWidth: 4, textureHeight: 3, capacity: 8), 8)
    }

    #if os(macOS)
    func testMetalPatchesPreserveOtherPixelsMipsAndLayers() throws { try patches(.metal) }
    #endif
    #if os(Windows) || os(Linux)
    func testVulkanPatchesPreserveOtherPixelsMipsAndLayers() throws { try patches(.vulkan) }
    #endif
    #if os(Windows)
    func testDX12PatchesPreserveOtherPixelsMipsAndLayers() throws { try patches(.dx12) }
    #endif

    private func patches(_ api: GraphicsAPI) throws {
        let device = try Device.make(DeviceConfig(preferredBackends: [api]))
        for format in [TextureFormat.r8Unorm, .rgba8Unorm, .bgra8UnormSRGB, .rgba16Float] {
            let texture = try device.makeTexture(TextureDescriptor(width: 10, height: 8, format: format,
                usage: [.sampled, .transferDestination, .transferSource], dimension: .texture2DArray, layers: 2, mipLevels: 3))
            defer { device.destroy(texture) }
            var expected: [TextureSubresource: Data] = [:]
            for layer in 0..<2 {
                for mip in 0..<3 {
                    let width = max(1, 10 >> mip), height = max(1, 8 >> mip)
                    let subresource = TextureSubresource(mipLevel: mip, layer: layer)
                    let initial = Data(repeating: UInt8(17 + mip * 9 + layer * 40), count: width * height * format.byteCount)
                    expected[subresource] = initial
                    try device.uploadTextureData(texture, data: initial, region: .init(width: width, height: height),
                        bytesPerRow: width * format.byteCount, subresource: subresource)
                }
            }
            for subresource in [TextureSubresource(mipLevel: 1, layer: 0), .init(mipLevel: 0, layer: 1), .init(mipLevel: 2, layer: 1)] {
                let width = max(1, 10 >> subresource.mipLevel), height = max(1, 8 >> subresource.mipLevel)
                var region = TextureUploadRegion(width: min(3, width - 1), height: min(2, height - 1))
                region.origin = SIMD2(width - region.width, height - region.height)
                let pitch = (region.width + 2) * format.byteCount
                var bytes = Data(repeating: 0xed, count: pitch * region.height)
                for y in 0..<region.height {
                    let patch = Data((0..<region.width * format.byteCount).map { UInt8(91 + $0 + y * 19) })
                    bytes.replaceSubrange(y * pitch..<y * pitch + patch.count, with: patch)
                    let destination = ((region.origin.y + y) * width + region.origin.x) * format.byteCount
                    expected[subresource]!.replaceSubrange(destination..<destination + patch.count, with: patch)
                }
                try device.uploadTextureData(texture, data: bytes, region: region, bytesPerRow: pitch, subresource: subresource)
            }
            var invalid = TextureUploadRegion(width: 1, height: 1); invalid.origin = SIMD2(10, 0)
            XCTAssertThrowsError(try device.uploadTextureData(texture, data: Data(count: format.byteCount),
                region: invalid, bytesPerRow: format.byteCount))
            for (subresource, bytes) in expected {
                let width = max(1, 10 >> subresource.mipLevel), height = max(1, 8 >> subresource.mipLevel)
                var actual = Data(count: bytes.count)
                try actual.withUnsafeMutableBytes {
                    try device.readTextureData(texture, width: width, height: height, bytesPerRow: width * format.byteCount,
                        subresource: subresource, into: $0)
                }
                XCTAssertEqual(actual, bytes, "format=\(format), mip=\(subresource.mipLevel), layer=\(subresource.layer)")
            }
        }
    }
}
