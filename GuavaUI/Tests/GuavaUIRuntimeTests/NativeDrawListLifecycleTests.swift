#if os(macOS)
import Foundation
import NativeRHI
import Testing
@testable import GuavaUIRuntime

@Suite("Native draw list resource lifecycle", .serialized)
struct NativeDrawListLifecycleTests {
    private let viewport = NativeUIViewport(pixels: SIMD2(32, 24), logical: SIMD2(32, 24))

    private func imageList(_ id: TextureID) -> DrawList {
        let list = DrawList()
        list.addImageQuad(rect: UIRect(x: 0, y: 0, width: 32, height: 24), textureID: id)
        return list
    }

    @Test("empty geometry still clears and resolves the attachment")
    func emptyFrame() throws {
        let context = try NativeUIDrawTestContext()
        for samples in [1, 4] {
            let format = NativeUITestFormat.cases[0]
            let (native, statistics) = try context.nativeImage(list: DrawList(), format: format, samples: samples, viewport: viewport)
            let reference = try context.referenceImage(list: DrawList(), format: format, samples: samples, viewport: viewport)
            try expectNativeUIParity(native, reference, format: format, label: "empty/\(samples)x")
            #expect(statistics.vertices == 0 && statistics.indices == 0 && statistics.drawCalls == 0)
            #expect(native[3] == 128)
        }
    }

    @Test("failed, abandoned and stale recordings preserve later patches")
    func retryAndAcknowledgement() throws {
        let context = try NativeUIDrawTestContext()
        try context.native.registerTexture(id: 2, pixels: Data(repeating: 31, count: 16), size: SIMD2(2, 2),
            region: .init(width: 2, height: 2), format: .rgba8Unorm)
        let slot = try #require(context.native.textureStore.textures[2])
        let output = try context.nativeOutput(format: .bgra8Unorm, size: viewport.pixels)
        let commands = CommandBuffer()
        #expect(throws: RHIError.self) {
            try context.native.record(list: imageList(2), into: commands, target: RenderColorTarget(texture: output.texture), viewport: viewport)
        }
        #expect(commands.commands.isEmpty && slot.snapshot().count == 1)
        try context.device.beginFrame(); defer { context.device.endFrame() }
        let abandoned = try context.native.record(list: imageList(2), into: commands,
            target: RenderColorTarget(texture: output.texture), viewport: viewport)
        #expect(abandoned.statistics.textureUploads == 2 && slot.snapshot().count == 1)
        // An incompatible attachment fails after recording, without submission.
        let bad = try context.nativeOutput(format: .rgba8Unorm, size: viewport.pixels)
        let failedCommands = CommandBuffer()
        _ = try context.native.record(list: imageList(2), into: failedCommands, target: RenderColorTarget(texture: bad.texture), viewport: viewport)
        #expect(throws: RHIError.self) { try context.device.submit(failedCommands) }
        #expect(slot.snapshot().count == 1)
        let retryCommands = CommandBuffer()
        let retry = try context.native.record(list: imageList(2), into: retryCommands,
            target: RenderColorTarget(texture: output.texture), viewport: viewport)
        var patch = TextureUploadRegion(width: 1, height: 1); patch.origin = SIMD2(1, 1)
        try context.native.registerTexture(id: 2, pixels: Data([200, 190, 180, 255]), size: SIMD2(2, 2), region: patch, format: .rgba8Unorm)
        try context.device.submit(retryCommands); try context.native.didSubmit(retry)
        #expect(slot.snapshot().count == 1)
        // A repeated acknowledgement cannot remove the new sequence.
        try context.native.didSubmit(retry)
        #expect(slot.snapshot().count == 1)
        let nextCommands = CommandBuffer()
        let next = try context.native.record(list: DrawList(), into: nextCommands,
            target: RenderColorTarget(texture: output.texture), viewport: viewport)
        #expect(next.statistics.textureUploads == 1 && next.statistics.textureUploadBytes == 4)
        try context.device.submit(nextCommands); try context.native.didSubmit(next)
        #expect(slot.snapshot().isEmpty)
        context.device.endFrame(); try context.device.waitUntilIdle()
        var actual = Data(count: 16)
        try actual.withUnsafeMutableBytes {
            try context.device.readTextureData(slot.resource.texture, width: 2, height: 2, bytesPerRow: 8, into: $0)
        }
        #expect(actual == Data(repeating: 31, count: 12) + Data([200, 190, 180, 255]))
    }

    @Test("initial partial textures are zeroed and siblings retain replaced resources")
    func resizeAndSiblingOwnership() throws {
        let context = try NativeUIDrawTestContext()
        var region = TextureUploadRegion(width: 1, height: 1); region.origin = SIMD2(1, 1)
        try context.native.registerTexture(id: 2, pixels: Data([0, 255, 0, 255]), size: SIMD2(3, 3), region: region, format: .rgba8Unorm)
        weak var old = context.native.textureStore.textures[2]?.resource
        let sibling = try context.native.makeSibling(format: .bgra8Unorm)
        let (_, stats) = try context.nativeImage(list: imageList(2), format: NativeUITestFormat.cases[1], samples: 1, viewport: viewport)
        #expect(stats.textureUploads == 3)
        var expected = Data(count: 36); expected.replaceSubrange(16..<20, with: [0, 255, 0, 255])
        #expect(try context.read(try #require(old)) == expected)
        try context.native.registerTexture(id: 2, pixels: Data([255, 0, 0, 255]), size: SIMD2(1, 1), region: .init(width: 1, height: 1), format: .rgba8Unorm)
        #expect(old != nil && sibling.textureStore.textures[2]?.resource === old)
        let (oldImage, _) = try context.nativeImage(list: imageList(2), format: NativeUITestFormat.cases[1], samples: 1, viewport: viewport, renderer: sibling)
        #expect(oldImage[0] != 0 || oldImage[2] != 255)
        try sibling.synchronizeTextures(from: context.native)
        #expect(old == nil)
        let (newImage, _) = try context.nativeImage(list: imageList(2), format: NativeUITestFormat.cases[1], samples: 1, viewport: viewport, renderer: sibling)
        #expect(newImage[0..<4] == Data([0, 0, 255, 255]))
        context.native.unregisterTexture(id: 2)
        #expect(sibling.textureStore.textures[2] != nil)
        try sibling.synchronizeTextures(from: context.native)
        #expect(sibling.textureStore.textures.isEmpty)
    }

    @Test("recorded frames own external images through asynchronous submission")
    func externalOwnershipAndDeviceValidation() throws {
        let context = try NativeUIDrawTestContext()
        var resource: TextureResource? = try context.nativeOutput(format: .bgra8Unorm, size: SIMD2(1, 1))
        weak var weakResource = resource
        try context.device.uploadTextureData(resource!.texture, data: Data([17, 89, 211, 255]),
            region: .init(width: 1, height: 1), bytesPerRow: 4)
        try context.native.registerExternalColorTexture(id: 2, resource: resource!)
        let output = try context.nativeOutput(format: .bgra8Unorm, size: viewport.pixels)
        try context.device.beginFrame(); defer { context.device.endFrame() }
        let commands = CommandBuffer()
        var frame: NativeUIDrawFrame? = try context.native.record(list: imageList(2), into: commands,
            target: RenderColorTarget(texture: output.texture), viewport: viewport)
        context.native.unregisterTexture(id: 2); resource = nil
        #expect(weakResource != nil)
        try context.device.submit(commands); try context.native.didSubmit(frame!)
        frame = nil
        #expect(weakResource == nil)
        context.device.endFrame(); try context.device.waitUntilIdle()
        #expect(try context.read(output)[0..<4] == Data([17, 89, 211, 255]))
        let foreign = try Device.make(DeviceConfig(preferredBackends: [.metal]))
        let foreignTexture = try TextureResource(device: foreign, descriptor: TextureDescriptor(width: 1, height: 1,
            format: .bgra8Unorm, usage: .sampled))
        #expect(throws: RHIError.self) { try context.native.registerExternalColorTexture(id: 2, resource: foreignTexture) }
        let foreignRenderer = try NativeDrawListRenderer(device: foreign)
        #expect(throws: RHIError.self) { try foreignRenderer.synchronizeTextures(from: context.native) }
        try context.device.beginFrame()
        let localFrame = try context.native.record(list: DrawList(), into: CommandBuffer(),
            target: RenderColorTarget(texture: output.texture), viewport: viewport)
        context.device.endFrame()
        #expect(throws: RHIError.self) { try foreignRenderer.didSubmit(localFrame) }
        for format in [TextureFormat.bgra8UnormSRGB, .r8Unorm, .rgba16Float] {
            let invalid = try context.nativeOutput(format: format, size: SIMD2(1, 1))
            #expect(throws: RHIError.self) { try context.native.registerExternalColorTexture(id: 2, resource: invalid) }
        }
    }

    @Test("two renderers keep frame geometry and uniforms isolated across upload chunks and ring reuse")
    func frameUploadsAndMultipleRenderers() throws {
        let context = try NativeUIDrawTestContext()
        let sibling = try context.native.makeSibling(format: .bgra8Unorm)
        let large = DrawList()
        for _ in 0..<60_000 { large.addRect(UIRect(x: -10, y: -10, width: 1, height: 1), color: .white) }
        large.addRect(UIRect(x: 2, y: 3, width: 10, height: 7), color: Color(red: 17, green: 189, blue: 211))
        #expect(large.vertices.count * UIVertex.stride > 4 * 1024 * 1024)
        let small = DrawList(); small.addRect(UIRect(x: 0, y: 0, width: 8, height: 6), color: Color(red: 201, green: 79, blue: 13))
        let otherViewport = NativeUIViewport(pixels: viewport.pixels, logical: SIMD2(16, 12))
        let first = try context.nativeOutput(format: .bgra8Unorm, size: viewport.pixels)
        let second = try context.nativeOutput(format: .bgra8Unorm, size: viewport.pixels)
        // Submit without an idle wait, exceeding the default frame-ring length.
        for _ in 0..<8 {
            try context.device.beginFrame()
            do {
                let commands = CommandBuffer()
                let a = try context.native.record(list: large, into: commands,
                    target: RenderColorTarget(texture: first.texture, loadAction: .clear(.zero)), viewport: viewport)
                let b = try sibling.record(list: small, into: commands,
                    target: RenderColorTarget(texture: second.texture, loadAction: .clear(.zero)), viewport: otherViewport)
                try context.device.submit(commands); try context.native.didSubmit(a); try sibling.didSubmit(b)
                context.device.endFrame()
            } catch { context.device.endFrame(); throw error }
        }
        try context.device.waitUntilIdle()
        let a = try context.read(first), b = try context.read(second)
        let firstPixel = (4 * 32 + 3) * 4
        #expect(a[firstPixel..<firstPixel + 4] == Data([211, 189, 17, 255]))
        #expect(a[0..<4] == Data(count: 4))
        #expect(b[0..<4] == Data([13, 79, 201, 255]))
        #expect(b[(12 * 32 + 16) * 4..<(12 * 32 + 16) * 4 + 4] == Data(count: 4))
    }

    @Test("invalid geometry, scissor and viewport never append partial commands")
    func validationIsAtomic() throws {
        let context = try NativeUIDrawTestContext()
        let output = try context.nativeOutput(format: .bgra8Unorm, size: viewport.pixels)
        try context.device.beginFrame(); defer { context.device.endFrame() }
        let valid = DrawList(); valid.addRect(UIRect(x: 0, y: 0, width: 1, height: 1), color: .white)
        for variant in 0..<5 {
            let invalid = DrawList()
            var vertices = valid.vertices, indices = valid.indices, batches = valid.batches
            switch variant {
            case 0: vertices[0].posX = .nan
            case 1: indices[0] = UInt32(vertices.count)
            case 2: batches[0].indexOffset = .max
            case 3: batches[0].indexCount = 4
            default: batches[0].scissor = UIRect(x: .infinity, y: 0, width: 1, height: 1)
            }
            invalid.load(vertices: vertices, indices: indices, batches: batches)
            let commands = CommandBuffer()
            #expect(throws: RHIError.self) {
                try context.native.record(list: invalid, into: commands, target: RenderColorTarget(texture: output.texture), viewport: viewport)
            }
            #expect(commands.commands.isEmpty)
        }
        let commands = CommandBuffer()
        #expect(throws: RHIError.self) {
            try context.native.record(list: valid, into: commands, target: RenderColorTarget(texture: output.texture),
                viewport: NativeUIViewport(pixels: SIMD2(Int.max, 24), logical: SIMD2(32, 24)))
        }
        #expect(commands.commands.isEmpty)
        #expect(throws: RHIError.self) { try context.native.configure(format: .r8Unorm) }
        let frame = try context.native.record(list: valid, into: commands,
            target: RenderColorTarget(texture: output.texture), viewport: viewport)
        try context.device.submit(commands); try context.native.didSubmit(frame)
        #expect(frame.statistics.drawCalls == 1)
        let full = try #require(try viewport.scissor(UIRect(x: -1e30, y: -1e30, width: 2e30, height: 2e30)))
        #expect(full.x == 0 && full.y == 0 && full.width == 32 && full.height == 24)
        #expect(try viewport.scissor(UIRect(x: 1e30, y: 0, width: 1, height: 1)) == nil)
        let atlas = FontAtlas(width: 16, height: 16)
        atlas.reset()
        #expect(atlas.isDirty)
        #expect(throws: RHIError.self) { try context.native.uploadFontAtlas(atlas, textureID: .none) }
        #expect(atlas.isDirty)
    }
}
#endif
