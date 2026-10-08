import Foundation
import XCTest
@testable import NativeRHI

final class NativeRecordedTextureUploadTests: XCTestCase {
    #if os(macOS)
    func testMetalRecordedRegionsAndRecovery() throws { try regionsAndRecovery(.metal) }
    #endif
    #if os(Windows) || os(Linux)
    func testVulkanRecordedRegionsAndRecovery() throws { try regionsAndRecovery(.vulkan) }
    #endif
    #if os(Windows)
    func testDX12RecordedRegionsAndRecovery() throws { try regionsAndRecovery(.dx12) }
    #endif

    private func regionsAndRecovery(_ api: GraphicsAPI) throws {
        let device = try Device.make(DeviceConfig(preferredBackends: [api]))
        for format in [TextureFormat.r8Unorm, .rgba8Unorm, .bgra8UnormSRGB, .rgba16Float] {
            let texture = try TextureResource(device: device, descriptor: TextureDescriptor(width: 12, height: 8,
                format: format, usage: [.sampled, .transferDestination, .transferSource], dimension: .texture2DArray,
                layers: 2, mipLevels: 3))
            var expected: [TextureSubresource: Data] = [:]
            for layer in 0..<2 { for mip in 0..<3 {
                let subresource = TextureSubresource(mipLevel: mip, layer: layer)
                let w = 12 >> mip, h = 8 >> mip
                let bytes = Data(repeating: UInt8(11 + layer * 31 + mip * 7), count: w * h * format.byteCount)
                expected[subresource] = bytes
                try device.uploadTextureData(texture.texture, data: bytes, region: .init(width: w, height: h),
                    bytesPerRow: w * format.byteCount, subresource: subresource)
            } }
            try device.beginFrame(); defer { device.endFrame() }
            let commands = CommandBuffer()
            for subresource in [TextureSubresource(mipLevel: 1, layer: 1), .init(mipLevel: 0, layer: 0), .init(mipLevel: 2, layer: 0)] {
                let w = 12 >> subresource.mipLevel, h = 8 >> subresource.mipLevel
                var region = TextureUploadRegion(width: 2, height: min(2, h)); region.origin = SIMD2(w - 2, h - region.height)
                let rowBytes = 4 * format.byteCount
                // Nonzero buffer offsets and padded rows must both be honored.
                var payload = Data(repeating: 0xed, count: 256 + rowBytes * region.height)
                for y in 0..<region.height {
                    let patch = Data((0..<2 * format.byteCount).map { UInt8(101 + y * 23 + $0) })
                    payload.replaceSubrange(256 + y * rowBytes..<256 + y * rowBytes + patch.count, with: patch)
                    let start = ((region.origin.y + y) * w + region.origin.x) * format.byteCount
                    expected[subresource]!.replaceSubrange(start..<start + patch.count, with: patch)
                }
                let location = try device.uploadTransient(payload)
                var upload = TextureBufferUpload(buffer: location.buffer, bytesPerRow: rowBytes, texture: texture.texture, region: region)
                upload.offset = location.offset + 256; upload.subresource = subresource
                commands.copyPass { $0.uploadBufferToTexture(upload) }
            }
            // An encoding failure may not poison the planner or submit earlier
            // blits: retry the valid command list within this same frame.
            let buffer = try device.makeBuffer(BufferDescriptor(size: 256, usage: .transferSource))
            defer { device.destroy(buffer) }
            var base = TextureBufferUpload(buffer: buffer, bytesPerRow: format.byteCount, texture: texture.texture,
                region: .init(width: 1, height: 1))
            for invalid in 0..<5 {
                var upload = base
                switch invalid {
                case 0: upload.offset = 256
                case 1: upload.region.origin.x = 12
                case 2: upload.subresource.mipLevel = 3
                case 3: upload.subresource.layer = 2
                default: upload.bytesPerRow = format.byteCount - 1
                }
                let failed = CommandBuffer(); failed.copyPass { $0.uploadBufferToTexture(upload) }
                XCTAssertThrowsError(try device.submit(failed))
            }
            base.offset = Int.max
            let overflowing = CommandBuffer(); overflowing.copyPass { $0.uploadBufferToTexture(base) }
            XCTAssertThrowsError(try device.submit(overflowing))
            try device.submit(commands); device.endFrame(); try device.waitUntilIdle()
            for (subresource, bytes) in expected {
                let w = 12 >> subresource.mipLevel, h = 8 >> subresource.mipLevel
                var actual = Data(count: bytes.count)
                try actual.withUnsafeMutableBytes {
                    try device.readTextureData(texture.texture, width: w, height: h, bytesPerRow: w * format.byteCount,
                        subresource: subresource, into: $0)
                }
                XCTAssertEqual(actual, bytes, "\(format), \(subresource)")
            }
        }
    }
}
