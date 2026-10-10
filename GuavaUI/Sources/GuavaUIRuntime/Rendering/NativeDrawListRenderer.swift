import Foundation
import NativeRHI

public struct NativeUIDrawStatistics: Sendable {
    public internal(set) var vertices = 0
    public internal(set) var indices = 0
    public internal(set) var drawCalls = 0
    public internal(set) var textureUploads = 0
    public internal(set) var textureUploadBytes = 0
}

struct NativeUITextureCommit {
    let slot: NativeUITextureSlot
    let sequence: UInt64
}

/// Retain until submission succeeds. Acknowledge with didSubmit; failed or
/// abandoned recording leaves texture patches available for the next frame.
public struct NativeUIDrawFrame {
    public let statistics: NativeUIDrawStatistics
    let pipeline: NativeUIPipeline
    let textures: [NativeUITextureSlot]
    let commits: [NativeUITextureCommit]

    /// Acknowledge this recording only after its commands were submitted.
    /// Ownership and update sequences travel with the token, so the caller
    /// does not need to retain or select the renderer that created it.
    public func didSubmit() {
        commits.forEach { $0.slot.commit(through: $0.sequence) }
    }
}

private struct NativeUIBatch {
    let indices: DrawBatch
    let scissor: ScissorRect
    let bindings: BindingSet
}

/// Consumes GuavaUI geometry on a caller-owned NativeRHI frame and command list.
/// Call methods serially per renderer. Siblings share immutable GPU resources;
/// their frame uploads and pending-patch acknowledgements remain independent.
public final class NativeDrawListRenderer {
    private let device: Device
    private let shaders: NativeUIShaderResources
    let textureStore: NativeUITextureStore
    private var pipeline: NativeUIPipeline?

    public init(device: Device) throws {
        self.device = device
        shaders = try NativeUIShaderResources(device: device)
        textureStore = try NativeUITextureStore(device: device)
    }
    private init(device: Device, shaders: NativeUIShaderResources) throws {
        self.device = device; self.shaders = shaders
        textureStore = try NativeUITextureStore(device: device)
    }

    public func configure(format: TextureFormat, sampleCount: Int = 1) throws {
        if pipeline?.format == format && pipeline?.samples == sampleCount { return }
        pipeline = try NativeUIPipeline(shaders: shaders, format: format, samples: sampleCount)
    }

    public func makeSibling(format: TextureFormat, sampleCount: Int = 1) throws -> NativeDrawListRenderer {
        let sibling = try NativeDrawListRenderer(device: device, shaders: shaders)
        try sibling.configure(format: format, sampleCount: sampleCount)
        try sibling.synchronizeTextures(from: self)
        return sibling
    }

    public func synchronizeTextures(from source: NativeDrawListRenderer) throws {
        try textureStore.synchronize(from: source.textureStore)
    }

    /// Stages tightly packed R8 or RGBA8 pixels. Initial partial registration
    /// zeroes untouched texels; uploads execute on the next recorded frame.
    public func registerTexture(id: TextureID, pixels: Data, size: SIMD2<Int>,
        region: TextureUploadRegion, format: TextureFormat) throws {
        try textureStore.stage(id: id, pixels: pixels, size: size, region: region, format: format)
    }

    public func registerExternalColorTexture(id: TextureID, resource: TextureResource) throws {
        try textureStore.register(id: id, resource: resource)
    }
    public func unregisterTexture(id: TextureID) { textureStore.unregister(id) }

    public func uploadFontAtlas(_ atlas: FontAtlas, textureID: TextureID) throws {
        guard textureID > 0 && textureID < 0x8000_0000 else { throw RHIError.invalidArgument("invalid font atlas texture ID") }
        if let payload = atlas.dirtyUploadPayload() {
            var region = TextureUploadRegion(width: payload.region.width, height: payload.region.height)
            region.origin = SIMD2(payload.region.x, payload.region.y)
            try registerTexture(id: textureID, pixels: Data(payload.pixels), size: SIMD2(atlas.atlasWidth, atlas.atlasHeight),
                region: region, format: .r8Unorm)
        }
        if let payload = atlas.colorDirtyUploadPayload() {
            var region = TextureUploadRegion(width: payload.region.width, height: payload.region.height)
            region.origin = SIMD2(payload.region.x, payload.region.y)
            try registerTexture(id: textureID.colorGlyphAtlasID, pixels: Data(payload.pixels),
                size: SIMD2(payload.textureWidth, payload.textureHeight), region: region, format: .rgba8Unorm)
        }
        // CPU payload ownership has transferred to the registry. It stays
        // pending until successful GPU submission acknowledges the frame.
        atlas.markClean()
    }

    public func record(list: DrawList, into commands: CommandBuffer, target: RenderColorTarget,
        viewport: NativeUIViewport) throws -> NativeUIDrawFrame {
        guard let pipeline else { throw RHIError.invalidArgument("configure the native UI renderer before recording") }
        try viewport.validate()
        try validate(list)
        try textureStore.prepareAssets(list.resources)
        var statistics = NativeUIDrawStatistics()
        statistics.vertices = list.vertices.count; statistics.indices = list.indices.count
        let slots = [textureStore.fallback] + textureStore.textures.keys.sorted().compactMap { textureStore.textures[$0] }
        var uploads: [TextureBufferUpload] = [], commits: [NativeUITextureCommit] = []
        for slot in slots {
            let patches = slot.snapshot()
            for patch in patches {
                let location = try device.uploadTransient(patch.pixels)
                let channels = slot.resource.descriptor.format == .r8Unorm ? 1 : 4
                var upload = TextureBufferUpload(buffer: location.buffer, bytesPerRow: patch.region.width * channels,
                    texture: slot.resource.texture, region: patch.region)
                upload.offset = location.offset; uploads.append(upload)
                statistics.textureUploads += 1; statistics.textureUploadBytes += patch.pixels.count
            }
            if let last = patches.last { commits.append(NativeUITextureCommit(slot: slot, sequence: last.sequence)) }
        }
        var draws: [NativeUIBatch] = []
        draws.reserveCapacity(list.batches.count)
        var vertices: UploadLocation?, indices: UploadLocation?
        if !list.indices.isEmpty && !list.batches.isEmpty {
            vertices = try list.vertices.withUnsafeBytes { try device.uploadTransient($0) }
            indices = try list.indices.withUnsafeBytes { try device.uploadTransient($0) }
            for batch in list.batches {
                guard batch.indexCount > 0, let scissor = try viewport.scissor(batch.scissor) else { continue }
                let bindings: BindingSet
                let slot = textureStore.textures[batch.textureID] ?? textureStore.fallback
                if let cached = slot.cachedBindingSet { bindings = cached }
                else {
                    bindings = try device.makeBindingSet(layout: shaders.bindings, descriptor: BindingSetDescriptor(entries: [
                        BindingSetEntry(slot: 1, resource: .texture(slot.resource.texture)),
                        BindingSetEntry(slot: 2, resource: .sampler(shaders.sampler))
                    ]))
                    slot.cachedBindingSet = bindings
                }
                draws.append(NativeUIBatch(indices: batch, scissor: scissor, bindings: bindings))
            }
        }
        // Append only after all validation, allocations and bindings succeed.
        if !uploads.isEmpty { commands.copyPass { pass in uploads.forEach { pass.uploadBufferToTexture($0) } } }
        commands.renderPass(descriptor: RenderPassDescriptor(colorTargets: [target])) { pass in
            pass.setPipeline(pipeline.handle)
            pass.setViewport(Viewport(width: Double(viewport.pixels.x), height: Double(viewport.pixels.y)))
            if let vertices, let indices, !draws.isEmpty {
                pass.setVertexBuffer(vertices.buffer, offset: vertices.offset)
                pass.setIndexBuffer(indices.buffer, offset: indices.offset, type: .uint32)
                // Constants belong to this recording. Image bindings have no
                // frame-dependent buffers and can hit the Device's cache even
                // as upload chunks, viewports and target formats change.
                pass.pushConstant(stage: .vertex, slot: shaders.constants.slot,
                    value: SIMD4(viewport.logical.x, viewport.logical.y, pipeline.srgb, Float(0)))
                var boundSet: BindingSet?
                var scissor: ScissorRect?
                for draw in draws {
                    if boundSet != draw.bindings {
                        pass.setBindingSet(draw.bindings); boundSet = draw.bindings
                    }
                    if scissor != draw.scissor {
                        pass.setScissor(draw.scissor); scissor = draw.scissor
                    }
                    pass.drawIndexed(DrawIndexedArguments(indexCount: Int(draw.indices.indexCount), firstIndex: Int(draw.indices.indexOffset)))
                }
            }
        }
        statistics.drawCalls = draws.count
        return NativeUIDrawFrame(statistics: statistics, pipeline: pipeline, textures: slots, commits: commits)
    }

    private func validate(_ list: DrawList) throws {
        // Read the cross-module array counts once for these bounds checks.
        let vertexCount = list.vertices.count, indexCount = list.indices.count
        guard list.vertices.allSatisfy({ $0.posX.isFinite && $0.posY.isFinite && $0.u.isFinite && $0.v.isFinite })
            && list.indices.allSatisfy({ Int($0) < vertexCount }) else {
            throw RHIError.invalidArgument("invalid UI vertices or indices")
        }
        for batch in list.batches {
            let offset = Int(batch.indexOffset), count = Int(batch.indexCount)
            guard offset <= indexCount && count <= indexCount - offset && count % 3 == 0 else {
                throw RHIError.invalidArgument("UI batch index range exceeds the draw list")
            }
        }
    }
}
