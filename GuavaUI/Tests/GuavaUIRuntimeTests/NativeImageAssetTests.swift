#if os(macOS)
import Foundation
import NativeRHI
import enum RHIWGPU.WGPUBackendError
import Testing
@testable import GuavaUIRuntime

@Suite("Native owned image asset delivery", .serialized)
struct NativeImageAssetTests {
    @Test("recording owns uploads through failure, cache clear and CPU lease expiration")
    func recoveryAndReclamation() throws {
        let context = try NativeUIDrawTestContext()
        let registry = ImageAssetRegistry()
        var asset: ImageAssetRegistry.Asset? = try registry.register(key: "red", decoded: .init(pixels: [233, 17, 99, 255], width: 1, height: 1))
        weak let lease = asset
        let id = asset!.textureID
        let list = image(asset!, x: 0)
        let viewport = NativeUIViewport(pixels: SIMD2(32, 16), logical: SIMD2(32, 16))
        let output = try context.nativeOutput(format: .bgra8Unorm, size: viewport.pixels)
        // First staging can happen before the active-frame check fails; the
        // renderer must retain the pending upload for a subsequent recording.
        #expect(throws: RHIError.self) {
            try context.native.record(list: list, into: CommandBuffer(), target: RenderColorTarget(texture: output.texture), viewport: viewport)
        }
        try context.device.beginFrame()
        let rejected = CommandBuffer()
        let abandoned = try context.native.record(list: list, into: rejected, target: RenderColorTarget(texture: output.texture), viewport: viewport)
        #expect(abandoned.statistics.textureUploadBytes == 8)
        rejected.copyPass { $0.copyTexture(src: output.texture, dst: output.texture, width: Int.max, height: 1) }
        #expect(throws: RHIError.self) { try context.device.submit(rejected) }
        context.device.endFrame()
        try context.device.beginFrame()
        let commands = CommandBuffer()
        let accepted = try context.native.record(list: list, into: commands, target: RenderColorTarget(texture: output.texture), viewport: viewport)
        #expect(accepted.statistics.textureUploadBytes == 8)
        registry.clear(); asset = nil; list.reset()
        #expect(lease == nil, "recording owns GPU slots independently of CPU cache/geometry")
        // Prune before the original recording is submitted. Its token must
        // still own the GPU image used by its bindings and upload commands.
        _ = try context.native.record(list: DrawList(), into: CommandBuffer(), target: RenderColorTarget(texture: output.texture), viewport: viewport)
        #expect(context.native.textureStore.textures[id] == nil)
        try context.device.submit(commands); accepted.didSubmit(); context.device.endFrame()
        #expect(try context.read(output)[0..<4] == Data([99, 17, 233, 255]))
    }

    @Test("independent registries, siblings and repeated frames preserve bitmap bindings without reupload")
    func multipleAssetsAndReuse() throws {
        let context = try NativeUIDrawTestContext()
        let registry = ImageAssetRegistry()
        let a = try registry.register(key: "same", decoded: .init(pixels: [255, 0, 0, 255], width: 1, height: 1))
        let b = try ImageAssetRegistry().register(key: "same", decoded: .init(pixels: [0, 255, 0, 255], width: 1, height: 1))
        registry.clear()
        let replacement = try registry.register(key: "same", decoded: .init(pixels: [0, 0, 255, 255], width: 1, height: 1))
        #expect(replacement.textureID != a.textureID)
        let list = image(a, x: 0); list.append(image(b, x: 16))
        list.append(image(replacement, x: 32))
        let viewport = NativeUIViewport(pixels: SIMD2(48, 16), logical: SIMD2(48, 16))
        let format = NativeUITestFormat.cases[1]
        let (first, statistics) = try context.nativeImage(list: list, format: format, samples: 1, viewport: viewport)
        #expect(statistics.textureUploadBytes == 16)
        #expect(first[0..<4] == Data([0, 0, 255, 255]))
        #expect(first[16*4..<17*4] == Data([0, 255, 0, 255]))
        #expect(first[32*4..<33*4] == Data([255, 0, 0, 255]))
        let sibling = try context.native.makeSibling(format: .bgra8Unorm)
        let (next, uploads) = try context.nativeImage(list: list, format: format, samples: 1, viewport: viewport, renderer: sibling)
        #expect(uploads.textureUploadBytes == 4, "sibling uploads only its independent white fallback")
        #expect(first == next)
        let (_, stable) = try context.nativeImage(list: list, format: format, samples: 1, viewport: viewport)
        #expect(stable.textureUploads == 0)
        let expected = try context.referenceImage(list: list, format: format, samples: 1, viewport: viewport)
        try expectNativeUIParity(first, expected, format: format, label: "owned-image-assets")
        let referenceSibling = try context.reference.makeSibling(format: format.reference)
        #expect(try context.referenceImage(list: list, format: format, samples: 1, viewport: viewport,
            renderer: referenceSibling) == expected)
        let foreign = try NativeUIDrawTestContext()
        #expect(throws: WGPUBackendError.self) { try foreign.reference.synchronizeTextures(from: context.reference) }
    }

    private func image(_ asset: ImageAssetRegistry.Asset, x: Float) -> DrawList {
        let list = DrawList(); list.retainResource(asset)
        list.addImageQuad(rect: UIRect(x: x, y: 0, width: 16, height: 16), textureID: asset.textureID)
        return list
    }
}
#endif
