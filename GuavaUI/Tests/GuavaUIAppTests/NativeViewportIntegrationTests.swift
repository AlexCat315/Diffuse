#if os(macOS)
import Foundation
import XCTest
import NativeRHI
import NativeRendererValidation
import RenderBackend
import RHIWGPU
import GuavaUICompose
import GuavaUIApp
@testable import GuavaUIRuntime

final class NativeViewportIntegrationTests: XCTestCase {
    func testMetalSceneAndPostViewportMatchWGPUAfterResize() throws {
        let context = try NativeViewportTestContext()
        let scene = try NativeRenderer(device: context.device)
        let sizes = [RenderDrawableSize(width: 192, height: 128), RenderDrawableSize(width: 64, height: 32),
            RenderDrawableSize(width: 256, height: 96)]
        for post in [false, true] {
            for (index, size) in sizes.enumerated() {
                var packet = post ? PostProbeScene.packet(size: size, frame: index + 3) : MeshProbeScene.packet(size: size, frame: index)
                // Both production renderers encode a full scene rather than
                // reusing temporal history from a different validation case.
                packet.renderSettings.enableTAA = false
                packet.renderSettings.enableSSR = false
                try scene.renderChecked(packet: packet); _ = try context.reference.render(packet: packet)
                let nativeSurface = scene.currentViewportSurfaceState()
                XCTAssertTrue(nativeSurface.isValid)
                let sourceDifference = try GridImage.difference(
                    GridImage.readback(device: context.device, texture: XCTUnwrap(scene.colorTexture), size: size), context.reference.readback())
                print("native-viewport-source post=\(post) size=\(size) delta=\(sourceDifference)")
                XCTAssertLessThan(sourceDifference.meanAbsoluteChannelError, 0.5)
                XCTAssertLessThan(Double(sourceDifference.pixelsOverThree) / Double(sourceDifference.pixelCount), 0.01)
                let nativeList = context.drawList(surface: nativeSurface, bridge: context.nativeBridge)
                let wgpuList = context.drawList(surface: context.reference.renderer.currentViewportSurfaceState(), bridge: context.wgpuBridge)
                let identicalSource = try context.referenceSurfaceForUIParity(context.reference.renderer.currentViewportSurfaceState())
                let parityList = context.drawList(surface: identicalSource, bridge: context.nativeBridge)
                XCTAssertEqual(nativeList.resources.count, 1)
                XCTAssertEqual(wgpuList.resources.count, 1)
                for output in ViewportTestOutput.cases {
                    let native = try context.nativeImage(nativeList, output: output)
                    let reference = try context.wgpuImage(wgpuList, output: output)
                    let uiOnly = try context.nativeImage(parityList, output: output)
                    let samplingDelta = try GridImage.difference(uiOnly, reference)
                    XCTAssertLessThanOrEqual(samplingDelta.maximumChannelError, 1, "same-source viewport UI must match")
                    let delta = try GridImage.difference(native, reference)
                    XCTAssertLessThan(delta.meanAbsoluteChannelError, 0.5, "\(post)/\(size)/\(output): \(delta)")
                    // Linear upscaling spreads the scene's small edge errors
                    // across neighboring display pixels. UI itself is checked
                    // against identical source pixels above with a 1-byte bound.
                    XCTAssertLessThan(Double(delta.pixelsOverThree) / Double(delta.pixelCount), 0.01)
                    print("native-viewport post=\(post) size=\(size) format=\(output.native) samples=\(output.samples) delta=\(delta)")
                    if post && index == 1 && output.native == .bgra8UnormSRGB && output.samples == 4 {
                        let size = RenderDrawableSize(width: 384, height: 256)
                        try GridImage.writePPM(native, size: size, to: URL(fileURLWithPath: "/tmp/guava-native-viewport.ppm"))
                        try GridImage.writePPM(reference, size: size, to: URL(fileURLWithPath: "/tmp/guava-wgpu-viewport.ppm"))
                    }
                }
            }
        }
    }

    func testOldAndNewImagesKeepDistinctBindingsThroughSnapshotsAndSubmission() throws {
        let context = try NativeViewportTestContext()
        var old: ViewportSurfaceState? = try context.solidSurface(SIMD4(1, 0, 0, 1))
        var new: ViewportSurfaceState? = try context.solidSurface(SIMD4(0, 1, 0, 1))
        weak let oldLease = old?.image
        weak let newLease = new?.image
        let oldID = try XCTUnwrap(context.nativeBridge.textureID(for: old!))
        let newID = try XCTUnwrap(context.nativeBridge.textureID(for: new!))
        XCTAssertNotEqual(oldID, newID, "producer-local surface IDs can coincide")
        XCTAssertEqual(context.nativeBridge.textureID(for: old!), oldID)
        let list = DrawList()
        list.retainResource(old!.image!); list.retainResource(new!.image!)
        list.addImageQuad(rect: UIRect(x: 0, y: 0, width: 96, height: 128), textureID: oldID)
        list.addImageQuad(rect: UIRect(x: 96, y: 0, width: 96, height: 128), textureID: newID)
        var snapshot = DrawListSnapshot(vertices: list.vertices, indices: list.indices, batches: list.batches,
            logicalSize: SIMD2(192, 128), resources: list.resources)
        old = nil; new = nil; list.reset(); context.nativeBridge.prune()
        XCTAssertNotNil(oldLease); XCTAssertNotNil(newLease)
        XCTAssertEqual(context.nativeUI.textureStore.textures.count, 2)
        let restored = DrawList()
        restored.load(vertices: snapshot.vertices, indices: snapshot.indices, batches: snapshot.batches, resources: snapshot.resources)
        snapshot.resources.reset()
        let output = try context.texture()
        try context.device.beginFrame()
        do {
            let commands = CommandBuffer()
            let frame = try context.nativeUI.record(list: restored, into: commands, target: RenderColorTarget(texture: output.texture),
                viewport: NativeUIViewport(pixels: context.size, logical: SIMD2(192, 128)))
            restored.reset(); context.nativeBridge.prune()
            XCTAssertNil(oldLease); XCTAssertNil(newLease)
            XCTAssertTrue(context.nativeUI.textureStore.textures.isEmpty)
            // The recording token owns borrowed textures until submission,
            // even when every source lease and registry binding is released.
            try context.device.submit(commands); frame.didSubmit()
            context.device.endFrame()
        } catch { context.device.endFrame(); throw error }
        let pixels = try GridImage.readback(device: context.device, texture: output.texture, size: .init(width: 384, height: 256))
        XCTAssertEqual(Array(pixels[0..<4]), [0, 0, 255, 255])
        XCTAssertEqual(Array(pixels[(383 * 4)..<(384 * 4)]), [0, 255, 0, 255])
    }

    func testLinearUpscalingNeverSamplesHighContrastPadding() throws {
        let context = try NativeViewportTestContext()
        let capacity = RenderDrawableSize(width: 8, height: 8)
        let previous = ViewportTextureBridgeHolder.current
        defer { ViewportTextureBridgeHolder.current = previous }
        for size in [RenderDrawableSize(width: 3, height: 2), .init(width: 1, height: 3), .init(width: 3, height: 1), .init(width: 1, height: 1)] {
            var pixels = Data()
            for y in 0..<8 { for x in 0..<8 {
                pixels.append(contentsOf: x < Int(size.width) && y < Int(size.height) ? [0, 255, 0, 255] : [255, 0, 255, 255])
            } }
            let native = try TextureResource(device: context.device, descriptor: TextureDescriptor(width: 8, height: 8,
                format: .bgra8Unorm, usage: [.sampled, .transferDestination]))
            try context.device.uploadTextureData(native.texture, data: pixels, region: .init(width: 8, height: 8), bytesPerRow: 32)
            let wgpu = try context.reference.backend.createTexture(width: 8, height: 8, format: .bgra8Unorm, usage: [.textureBinding, .copyDst])
            pixels.withUnsafeBytes { bytes in
                context.reference.backend.writeTexture(wgpu, data: bytes.baseAddress!, dataSize: bytes.count,
                    bytesPerRow: 32, rowsPerImage: 8, width: 8, height: 8)
            }
            let region = ViewportSamplingRegion(size: size, capacity: capacity)
            let nativeState = ViewportSurfaceState(surfaceID: 1, image: ViewportImage(storage: .native(native)), region: region)
            let wgpuState = ViewportSurfaceState(surfaceID: 1, image: ViewportImage(storage: .wgpu(wgpu)), region: region)
            let lists = [(nativeState, context.nativeBridge), (wgpuState, context.wgpuBridge)].map { surface, bridge in
                ViewportTextureBridgeHolder.current = bridge
                let host = ViewportHost(surface: surface), node = host._makeNode()
                node.frame = CGRect(x: 0.13, y: 0.27, width: 191.4, height: 127.3); host._updateNode(node)
                let list = DrawList(); node.draw?(list, .zero)
                XCTAssertEqual(list.batches.count, 1)
                return list
            }
            for output in ViewportTestOutput.cases {
                let actual = try context.nativeImage(lists[0], output: output)
                let expected = try context.wgpuImage(lists[1], output: output)
                XCTAssertEqual(actual, expected)
                for y in 2..<(context.size.y - 2) {
                    let begin = (y * context.size.x + 2) * 4, end = (y * context.size.x + context.size.x - 2) * 4
                    let green = Data(Array(repeating: [UInt8(0), 255, 0, 255], count: context.size.x - 4).flatMap { $0 })
                    XCTAssertEqual(actual[begin..<end], green, "\(size), \(output) must exclude every padding texel")
                }
            }
        }
    }

    func testBridgeRejectsMismatchedDevicesAndBackends() throws {
        let context = try NativeViewportTestContext()
        let foreign = try Device.make(DeviceConfig(preferredBackends: [.metal]))
        let other = try context.solidSurface(SIMD4(1, 0, 0, 1), device: foreign)
        XCTAssertNil(context.nativeBridge.textureID(for: other))
        XCTAssertNil(context.wgpuBridge.textureID(for: other))
        let size = RenderDrawableSize(width: 4, height: 4)
        let texture = try context.reference.backend.createTexture(width: 4, height: 4, format: .bgra8Unorm, usage: [.textureBinding, .renderAttachment])
        let wgpu = ViewportSurfaceState(surfaceID: 1, image: ViewportImage(storage: .wgpu(texture)), region: .init(size: size, capacity: size))
        XCTAssertNil(context.nativeBridge.textureID(for: wgpu))
        XCTAssertNotNil(context.wgpuBridge.textureID(for: wgpu))
        XCTAssertTrue(context.nativeUI.textureStore.textures.isEmpty)
    }
}
#endif
