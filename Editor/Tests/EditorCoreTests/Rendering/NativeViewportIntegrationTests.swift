@testable import EditorCore
#if os(macOS)
import Foundation
import XCTest
import NativeRHI
import NativeRendererValidation
import RenderBackend
import GuavaUICompose
import GuavaUI
@testable import GuavaUIRuntime

final class NativeViewportIntegrationTests: XCTestCase {
    func testSceneAndPostViewportRemainVisibleAfterResize() throws {
        let context = try NativeViewportTestContext()
        let scene = try NativeRenderer(device: context.device)
        for post in [false, true] {
            for size in [RenderDrawableSize(width: 192, height: 128), .init(width: 64, height: 32), .init(width: 256, height: 96)] {
                var packet = post ? PostProbeScene.packet(size: size) : MeshProbeScene.packet(size: size)
                packet.renderSettings.postProcessing.taa = false; packet.renderSettings.postProcessing.ssr = false
                try scene.renderChecked(packet: packet)
                let surface = scene.currentViewportSurfaceState()
                XCTAssertTrue(surface.isValid)
                XCTAssertEqual(surface.region.size, size)
                let list = context.drawList(surface: surface)
                XCTAssertEqual(list.resources.count, 1)
                for output in ViewportTestOutput.cases {
                    let pixels = try context.nativeImage(list, output: output)
                    XCTAssertEqual(pixels.count, context.size.x * context.size.y * 4)
                    XCTAssertGreaterThan(Set(stride(from: 0, to: pixels.count, by: 4).map { pixels[$0] }).count, 8)
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
        var oldImage: TextureImage? = try TextureImage(texture: old!.image!.resource)
        var newImage: TextureImage? = try TextureImage(texture: new!.image!.resource)
        let oldID = oldImage!.textureID, newID = newImage!.textureID
        XCTAssertNotEqual(oldID, newID, "producer-local surface IDs can coincide")
        let list = DrawList()
        list.retainResource(oldImage!); list.retainResource(newImage!)
        list.addImageQuad(rect: UIRect(x: 0, y: 0, width: 96, height: 128), textureID: oldID)
        list.addImageQuad(rect: UIRect(x: 96, y: 0, width: 96, height: 128), textureID: newID)
        var snapshot = DrawListSnapshot(vertices: list.vertices, indices: list.indices, batches: list.batches,
            logicalSize: SIMD2(192, 128), resources: list.resources)
        old = nil; new = nil; oldImage = nil; newImage = nil; list.reset()
        // The owned GPU images retain the texture resources independently of
        // the scene publication objects.
        XCTAssertNil(oldLease); XCTAssertNil(newLease)
        XCTAssertEqual(snapshot.resources.count, 2)
        let restored = DrawList()
        restored.load(vertices: snapshot.vertices, indices: snapshot.indices, batches: snapshot.batches, resources: snapshot.resources)
        snapshot.resources.reset()
        let output = try context.texture()
        try context.device.beginFrame()
        do {
            let commands = CommandBuffer()
            let frame = try context.nativeUI.record(list: restored, into: commands, target: RenderColorTarget(texture: output.texture),
                viewport: NativeUIViewport(pixels: context.size, logical: SIMD2(192, 128)))
            restored.reset()
            XCTAssertNil(oldLease); XCTAssertNil(newLease)
            XCTAssertEqual(context.nativeUI.textureStore.textures.count, 2)
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
        for size in [RenderDrawableSize(width: 3, height: 2), .init(width: 1, height: 3), .init(width: 3, height: 1), .init(width: 1, height: 1)] {
            var pixels = Data()
            for y in 0..<8 { for x in 0..<8 {
                pixels.append(contentsOf: x < Int(size.width) && y < Int(size.height) ? [0, 255, 0, 255] : [255, 0, 255, 255])
            } }
            let native = try TextureResource(device: context.device, descriptor: TextureDescriptor(width: 8, height: 8,
                format: .bgra8Unorm, usage: [.sampled, .transferDestination]))
            try context.device.uploadTextureData(native.texture, data: pixels, region: .init(width: 8, height: 8), bytesPerRow: 32)
            let region = ViewportSamplingRegion(size: size, capacity: capacity)
            let nativeState = ViewportSurfaceState(surfaceID: 1, image: ViewportImage(resource: native), region: region)
            let lists = [nativeState].map { surface in
                let host = ViewportHost(surface: surface), node = host._makeNode()
                node.frame = CGRect(x: 0.13, y: 0.27, width: 191.4, height: 127.3); host._updateNode(node)
                let list = DrawList(); node.draw?(list, .zero)
                XCTAssertEqual(list.batches.count, 1)
                return list
            }
            for output in ViewportTestOutput.cases {
                let actual = try context.nativeImage(lists[0], output: output)
                for y in 2..<(context.size.y - 2) {
                    let begin = (y * context.size.x + 2) * 4, end = (y * context.size.x + context.size.x - 2) * 4
                    let green = Data(Array(repeating: [UInt8(0), 255, 0, 255], count: context.size.x - 4).flatMap { $0 })
                    XCTAssertEqual(actual[begin..<end], green, "\(size), \(output) must exclude every padding texel")
                }
            }
        }
    }

    func testBridgeRejectsMismatchedDevices() throws {
        let context = try NativeViewportTestContext()
        let foreign = try Device.make(DeviceConfig(preferredBackends: [.metal]))
        let other = try context.solidSurface(SIMD4(1, 0, 0, 1), device: foreign)
        let list = context.drawList(surface: other)
        XCTAssertThrowsError(try context.nativeImage(list, output: ViewportTestOutput.cases[0]))
        XCTAssertTrue(context.nativeUI.textureStore.textures.isEmpty)
    }
}
#endif
