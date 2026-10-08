#if os(macOS)
import XCTest
import NativeRHI
import NativeRendererValidation
@testable import RenderBackend

final class NativeViewportSurfaceTests: XCTestCase {
    func testScenePublicationTracksUsedRegionAndSuccessfulSubmission() throws {
        let device = try Device.make(DeviceConfig(preferredBackends: [.metal], enableValidation: true))
        let renderer = try NativeRenderer(device: device)
        var packet = MeshProbeScene.packet(size: RenderDrawableSize(width: 96, height: 64))
        try renderer.renderChecked(packet: packet)
        let first = renderer.currentViewportSurfaceState()
        XCTAssertTrue(first.isValid)
        guard case .native(let original) = first.image?.storage else { return XCTFail("missing native image") }
        XCTAssertEqual(original.texture, renderer.colorTexture)
        packet.drawableSize = RenderDrawableSize(width: 48, height: 32)
        try renderer.renderChecked(packet: packet)
        let smaller = renderer.currentViewportSurfaceState()
        XCTAssertTrue(smaller.image === first.image)
        XCTAssertEqual(smaller.surfaceID, first.surfaceID)
        XCTAssertEqual(smaller.region.capacity, first.region.capacity)
        XCTAssertEqual(smaller.region.size, packet.drawableSize)
        XCTAssertEqual(smaller.region.uvMax.x, Float(48) / Float(first.region.capacity.width))

        // Allocation succeeds but submission cannot start while another host
        // owns the Device's frame. Keep the last successful image published.
        try device.beginFrame()
        packet.drawableSize = RenderDrawableSize(width: first.region.capacity.width + 1, height: first.region.capacity.height + 1)
        XCTAssertThrowsError(try renderer.renderChecked(packet: packet))
        device.endFrame()
        XCTAssertEqual(renderer.currentViewportSurfaceState(), smaller)
        try renderer.renderChecked(packet: packet)
        let grown = renderer.currentViewportSurfaceState()
        XCTAssertTrue(grown.isValid && grown.surfaceID > smaller.surfaceID)
        XCTAssertFalse(grown.image === smaller.image)
        try device.waitUntilIdle()
        XCTAssertFalse(try GridImage.readback(device: device, texture: original.texture, size: smaller.region.size).isEmpty)
    }

    func testHeldSurfaceOutlivesFortyReplacementsAndRenderer() throws {
        let device = try Device.make(DeviceConfig(preferredBackends: [.metal], enableValidation: true, framesInFlight: 3))
        var renderer: NativeGridRenderer? = try NativeGridRenderer(device: device)
        var packet = GridProbeScene.packet(size: RenderDrawableSize(width: 32, height: 24))
        try renderer!.renderChecked(packet: packet)
        var retained: ViewportSurfaceState? = renderer!.currentViewportSurfaceState()
        weak let lease = retained?.image
        let expected: Data
        if case .native(let resource) = retained?.image?.storage {
            expected = try GridImage.readback(device: device, texture: resource.texture, size: packet.drawableSize)
        } else { return XCTFail("missing native image") }
        for frame in 1...40 {
            packet.frameIndex = frame
            packet.drawableSize.width = UInt32(32 + frame)
            try renderer!.renderChecked(packet: packet)
        }
        renderer = nil
        XCTAssertNotNil(lease)
        if case .native(let resource) = retained?.image?.storage {
            XCTAssertEqual(try GridImage.readback(device: device, texture: resource.texture, size: retained!.region.size), expected)
        } else { XCTFail("held image lost its resource") }
        retained = nil
        XCTAssertNil(lease)
    }

    func testInvalidSamplingRegionsAreRejected() throws {
        let device = try Device.make(DeviceConfig(preferredBackends: [.metal]))
        let resource = try TextureResource(device: device, descriptor: TextureDescriptor(width: 8, height: 8,
            format: .bgra8Unorm, usage: [.sampled, .colorTarget]))
        var state = ViewportSurfaceState(surfaceID: 1, image: ViewportImage(storage: .native(resource)),
            region: ViewportSamplingRegion(size: RenderDrawableSize(width: 4, height: 6), capacity: RenderDrawableSize(width: 8, height: 8)))
        XCTAssertTrue(state.isValid)
        state.region.size.width = 9
        XCTAssertFalse(state.isValid)
        XCTAssertEqual(state.region.uvMax, .zero)
        state.region.size.width = 4; state.region.capacity.width = 16
        XCTAssertFalse(state.isValid)
    }
}
#endif
