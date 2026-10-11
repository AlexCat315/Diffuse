#if os(macOS)
import Foundation
import NativeRHI
import NativeRendererValidation
import RenderBackend
import XCTest
@testable import GuavaUIRuntime
import GuavaUICompose
import GuavaUIApp

struct ViewportTestOutput {
    let native: TextureFormat
    let samples: Int
    static let cases = [Self(native: .bgra8Unorm, samples: 1),
        Self(native: .bgra8Unorm, samples: 4),
        Self(native: .bgra8UnormSRGB, samples: 1),
        Self(native: .bgra8UnormSRGB, samples: 4)]
}

final class NativeViewportTestContext {
    let device: Device
    let nativeUI: NativeDrawListRenderer
    let reference: SceneCapture
    let nativeBridge: ViewportTextureRegistry
    let size = SIMD2<Int>(384, 256)

    init() throws {
        device = try Device.make(DeviceConfig(preferredBackends: [.metal], enableValidation: true, framesInFlight: 3))
        nativeUI = try NativeDrawListRenderer(device: device)
        try nativeUI.configure(format: .bgra8Unorm)
        nativeBridge = ViewportTextureRegistry(renderer: nativeUI)
        reference = try SceneCapture(validation: true)
    }

    func drawList(surface: ViewportSurfaceState, bridge: ViewportTextureRegistry) -> DrawList {
        let previous = ViewportTextureBridgeHolder.current, scale = ContentScaleHolder.current
        ViewportTextureBridgeHolder.current = bridge; ContentScaleHolder.current = 2
        defer { ViewportTextureBridgeHolder.current = previous; ContentScaleHolder.current = scale }
        let host = ViewportHost(surface: surface, contentAspectRatio: Float(surface.region.size.width) / Float(surface.region.size.height),
            onDrawOverlay: { list, frame in
                list.addRoundedRectStroke(UIRect(x: frame.x + 4, y: frame.y + 4, width: 20, height: 12),
                    radius: 2, width: 1, color: .white)
            }) { EmptyView() }
        let node = host._makeNode(); node.frame = CGRect(x: 8, y: 8, width: 176, height: 98); host._updateNode(node)
        let list = DrawList()
        list.addRect(UIRect(x: 0, y: 0, width: 192, height: 128), color: Color(r: 0.12, g: 0.14, b: 0.18))
        list.pushClip(UIRect(x: 10, y: 9, width: 172, height: 96))
        node.draw?(list, .zero); list.popClip()
        list.addRoundedRect(UIRect(x: 8, y: 111, width: 65, height: 10), radius: 3, color: Color(r: 0.2, g: 0.5, b: 0.8, a: 0.8))
        return list
    }

    func texture(format: TextureFormat = .bgra8Unorm, samples: Int = 1) throws -> TextureResource {
        try TextureResource(device: device, descriptor: TextureDescriptor(width: size.x, height: size.y,
            format: format, usage: samples == 1 ? [.colorTarget, .sampled, .transferSource] : .colorTarget, sampleCount: samples))
    }

    func nativeImage(_ list: DrawList, output: ViewportTestOutput) throws -> Data {
        try nativeUI.configure(format: output.native, sampleCount: output.samples)
        let resolved = try texture(format: output.native)
        let ms = output.samples > 1 ? try texture(format: output.native, samples: output.samples) : nil
        var target = RenderColorTarget(texture: (ms ?? resolved).texture, loadAction: .clear(SIMD4(0, 0, 0, 1)))
        if ms != nil { target.resolveTexture = resolved.texture; target.store = false }
        try device.beginFrame()
        do {
            let commands = CommandBuffer()
            let frame = try nativeUI.record(list: list, into: commands, target: target,
                viewport: NativeUIViewport(pixels: size, logical: SIMD2(192, 128)))
            XCTAssertEqual(frame.statistics.textureUploadBytes, frame.statistics.textureUploads == 0 ? 0 : 4,
                "viewport pixels must not be re-uploaded by the UI")
            try device.submit(commands); frame.didSubmit()
            device.endFrame()
        } catch { device.endFrame(); throw error }
        return try GridImage.readback(device: device, texture: resolved.texture,
            size: RenderDrawableSize(width: UInt32(size.x), height: UInt32(size.y)))
    }

    func solidSurface(_ color: SIMD4<Float>, device other: Device? = nil) throws -> ViewportSurfaceState {
        let owner = other ?? device
        let resource = try TextureResource(device: owner, descriptor: TextureDescriptor(width: 4, height: 4,
            format: .bgra8Unorm, usage: [.colorTarget, .sampled]))
        try owner.beginFrame()
        do {
            let commands = CommandBuffer()
            commands.renderPass(descriptor: RenderPassDescriptor(colorTargets: [RenderColorTarget(texture: resource.texture, loadAction: .clear(color))])) { _ in }
            try owner.submit(commands); owner.endFrame()
        } catch { owner.endFrame(); throw error }
        let size = RenderDrawableSize(width: 4, height: 4)
        return ViewportSurfaceState(surfaceID: 1, image: ViewportImage(resource: resource), region: .init(size: size, capacity: size))
    }


}
#endif
