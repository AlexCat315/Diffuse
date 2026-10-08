import Foundation
@testable import NativeRHI
import XCTest

final class NativeTextureCopyTests: XCTestCase {
    func testColorCopyRejectsOutOfRangeAndMismatchedFormats() throws {
        let source = (width: 4,height: 4,format: TextureFormat.rgba16Float)
        let destination = (width: 6,height: 6,format: TextureFormat.rgba16Float)
        try rhiColorTextureCopyExtent(width: 3,height: 2,source: source,destination: destination)
        for size in [(0,1),(-1,1),(1,0),(5,1),(1,5)] {
            XCTAssertThrowsError(try rhiColorTextureCopyExtent(width: size.0,height: size.1,source: source,destination: destination))
        }
        XCTAssertThrowsError(try rhiColorTextureCopyExtent(width: 1,height: 1,source: source,destination: (6,6,.rgba8Unorm)))
        XCTAssertThrowsError(try rhiColorTextureCopyExtent(width: 1,height: 1,source: (4,4,.depth32Float),destination: (4,4,.depth32Float)))
    }
    #if os(macOS)
    func testMetalChainedTextureCopiesPreservePixelsAndUnusedRegion() throws { try copy(.metal) }
    #endif
    #if os(Windows) || os(Linux)
    func testVulkanChainedTextureCopiesPreservePixelsAndUnusedRegion() throws { try copy(.vulkan) }
    #endif
    #if os(Windows)
    func testDX12ChainedTextureCopiesPreservePixelsAndUnusedRegion() throws { try copy(.dx12) }
    #endif
    private func copy(_ api: GraphicsAPI) throws {
        let device = try Device.make(DeviceConfig(preferredBackends: [api],enableValidation: false))
        let usage: TextureUsage = [.transferSource,.transferDestination,.sampled]
        let source = try device.makeTexture(TextureDescriptor(width: 4,height: 4,format: .rgba16Float,usage: usage))
        let middle = try device.makeTexture(TextureDescriptor(width: 6,height: 6,format: .rgba16Float,usage: usage))
        let output = try device.makeTexture(TextureDescriptor(width: 6,height: 6,format: .rgba16Float,usage: usage))
        defer { [source,middle,output].forEach { device.destroy($0) } }
        let pixels = Data((0..<128).map { UInt8($0) })
        try device.uploadTextureData(source,data: pixels,width: 4,height: 4,bytesPerRow: 32)
        for target in [middle,output] { try device.uploadTextureData(target,data: Data(count: 288),width: 6,height: 6,bytesPerRow: 48) }
        let commands = CommandBuffer()
        commands.copyPass {
            $0.copyTexture(src: source,dst: middle,width: 3,height: 2)
            $0.copyTexture(src: middle,dst: output,width: 3,height: 2)
        }
        try device.beginFrame(); try device.submit(commands); device.endFrame(); try device.waitUntilIdle()
        var actual = Data(count: 288), expected = Data(count: 288)
        for y in 0..<2 { expected.replaceSubrange(y*48..<y*48+24,with: pixels[y*32..<y*32+24]) }
        try actual.withUnsafeMutableBytes { try device.readTextureData(output,width: 6,height: 6,bytesPerRow: 48,into: $0) }
        XCTAssertEqual(actual,expected)
    }
}
