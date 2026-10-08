#if os(macOS)
import Foundation
import XCTest
import RHIWGPU
@testable import RenderBackend

final class WGPUViewportOwnershipTests: XCTestCase {
    func testTypedSurfaceOutlivesFortyReplacementsAndRenderer() throws {
        let backend = WGPUBackend(config: WGPUDeviceConfig(validationEnabled: true, preferredBackends: [.metal]))
        try backend.initialize()
        var renderer: WGPURenderer? = WGPURenderer(backend: backend)
        let size = RenderDrawableSize(width: 4, height: 4)
        renderer!.registerViewportSurface(texture: try colorTexture(backend, color: GPUColor(r: 1, g: 0, b: 0, a: 1)), size: size, textureSize: size)
        var retained: ViewportSurfaceState? = renderer!.currentViewportSurfaceState()
        weak let lease = retained?.image
        XCTAssertTrue(retained!.isValid)
        let expected = try read(retained!, backend: backend)
        XCTAssertEqual(Array(expected.prefix(4)), [0, 0, 255, 255])
        if case .wgpu(let texture) = retained?.image?.storage {
            renderer!.registerViewportSurface(texture: texture, size: .init(width: 2, height: 3), textureSize: size)
        }
        XCTAssertTrue(renderer!.currentViewportSurfaceState().image === retained!.image)
        XCTAssertEqual(renderer!.currentViewportSurfaceState().surfaceID, retained!.surfaceID)
        for _ in 0..<40 {
            renderer!.registerViewportSurface(texture: try colorTexture(backend, color: GPUColor(r: 0, g: 1, b: 0, a: 1)), size: size, textureSize: size)
        }
        renderer = nil
        XCTAssertNotNil(lease)
        XCTAssertEqual(try read(retained!, backend: backend), expected)
        retained = nil
        XCTAssertNil(lease)
        try backend.waitUntilIdle()
    }

    private func colorTexture(_ backend: WGPUBackend, color: GPUColor) throws -> GPUTexture {
        let texture = try backend.createTexture(width: 4, height: 4, format: .bgra8Unorm, usage: [.renderAttachment, .textureBinding, .copySrc])
        let encoder = try backend.createCommandEncoder()
        let pass = try encoder.beginRenderPass(colorView: texture.createView(), clearColor: color)
        pass.end(); backend.submit(try encoder.finish())
        return texture
    }
    private func read(_ surface: ViewportSurfaceState, backend: WGPUBackend) throws -> Data {
        guard case .wgpu(let texture) = surface.image?.storage else { throw WGPUBackendError.initFailed("missing typed viewport") }
        let buffer = try backend.createBuffer(size: 1024, usage: [.copyDst, .mapRead])
        let encoder = try backend.createCommandEncoder()
        encoder.copyTextureToBuffer(source: texture, destination: buffer, bytesPerRow: 256, rowsPerImage: 4, width: 4, height: 4)
        backend.submit(try encoder.finish()); try backend.bufferMapSync(buffer)
        defer { buffer.unmap() }
        let pointer = try XCTUnwrap(buffer.getMappedRange())
        var data = Data()
        for y in 0..<4 { data.append(pointer.advanced(by: y * 256).assumingMemoryBound(to: UInt8.self), count: 16) }
        return data
    }
}
#endif
