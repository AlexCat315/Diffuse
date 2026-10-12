import Foundation
import NativeRHI
import GuavaUICore
import GuavaUIRendering
import GuavaUIComposeCore

private final class ProbeImage: UITextureAsset {
    let textureID: TextureID = 1024
    let image = DecodedImage(pixels: [255, 0, 255, 255], width: 1, height: 1)
}

extension ProbeContext {
    func ui(samples: Int) throws -> String {
        let renderer = try NativeDrawListRenderer(device: device)
        try renderer.configure(format: .rgba8Unorm, sampleCount: samples)
        let list = DrawList()
        list.addRect(UIRect(x: 8, y: 8, width: 48, height: 24), color: Color(r: 0, g: 0.5, b: 1))
        list.pushClip(UIRect(x: 20, y: 40, width: 24, height: 16))
        list.addRect(UIRect(x: 0, y: 36, width: 64, height: 24), color: Color(r: 1, g: 0.5, b: 0))
        list.popClip()
        let image = ProbeImage()
        list.retainResource(image)
        list.addImageQuad(rect: UIRect(x: 48, y: 40, width: 8, height: 16), textureID: image.textureID)
        let target = try device.makeTexture(TextureDescriptor(width: 64, height: 64, format: .rgba8Unorm,
            usage: [.colorTarget, .transferSource]))
        let color = samples == 1 ? target : try device.makeTexture(TextureDescriptor(width: 64, height: 64,
            format: .rgba8Unorm, usage: .colorTarget, sampleCount: samples))
        defer { if samples != 1 { device.destroy(color) }; device.destroy(target) }
        try device.beginFrame()
        var frameActive = true
        defer { if frameActive { device.endFrame() } }
        let commands = CommandBuffer()
        var attachment = RenderColorTarget(texture: color, loadAction: .clear(SIMD4(0, 0, 0, 1)))
        if samples != 1 { attachment.resolveTexture = target }
        let frame = try renderer.record(list: list, into: commands, target: attachment,
            viewport: NativeUIViewport(pixels: SIMD2(64, 64), logical: SIMD2(64, 64)))
        try device.submit(commands)
        frame.didSubmit()
        device.endFrame(); frameActive = false
        try device.waitUntilIdle()
        let pixels = try read(target, width: 64, height: 64)
        func pixel(_ x: Int, _ y: Int) -> [UInt8] { Array(pixels[(y * 64 + x) * 4..<(y * 64 + x) * 4 + 4]) }
        try require(pixel(16, 16) == [0, 128, 255, 255], "UI color mismatch: \(pixel(16, 16))")
        try require(pixel(32, 48) == [255, 128, 0, 255], "UI clipped fill mismatch")
        try require(pixel(52, 48) == [255, 0, 255, 255], "UI retained image/sampled texture mismatch")
        try require(pixel(8, 48) == [0, 0, 0, 255], "UI scissor mismatch")
        try writeImage(pixels, width: 64, height: 64, name: "guavaui-\(samples)x")
        return "production GuavaUI DrawList + NativeDrawListRenderer: colors, clipping, retained image upload/sampling, \(samples)x samples"
    }
}
