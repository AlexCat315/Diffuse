import Foundation
import RHIWGPU

/// GPU-side renderer that consumes a `DrawList` and submits draw calls.
///
/// Lifecycle:
///   1. `init(backend:)`
///   2. `configure(format:)` after the surface format is known
///   3. `registerTexture(...)` for each font atlas
///   4. each frame: `render(list:passEncoder:viewport:)`
public final class DrawListRenderer {

    private enum TextureSampling {
        case alphaMask
        case color
    }

    private let backend: WGPUBackend
    private var pipeline: GPURenderPipeline?
    private var bindGroupLayout: GPUBindGroupLayout?
    private var pipelineLayout: GPUPipelineLayout?
    private var alphaSampler: GPUSampler?
    private var colorSampler: GPUSampler?
    private var uniformBuffer: GPUBuffer?

    /// Vertex / index streaming buffers grow as needed.
    private var vertexBuffer: GPUBuffer?
    private var vertexCapacity: Int = 0
    private var indexBuffer: GPUBuffer?
    private var indexCapacity: Int = 0

    /// Registered font/image textures keyed by `TextureID`.
    private struct GPUTextureSlot {
        let texture: GPUTexture
        let view: GPUTextureView
        let bindGroup: GPUBindGroup
        let sampling: TextureSampling
        let width: UInt32
        let height: UInt32
    }
    private var textures: [TextureID: GPUTextureSlot] = [:]

    /// 1×1 white texture used for solid-color batches (sampled but ignored by shader).
    private var dummyTexture: GPUTexture?
    private var dummyView: GPUTextureView?
    private var dummyBindGroup: GPUBindGroup?

    /// Surface format used at pipeline creation time. Pipelines must be recreated
    /// if the format changes.
    private var configuredFormat: GPUTextureFormat?

    public init(backend: WGPUBackend) {
        self.backend = backend
    }

    // MARK: - Configuration

    /// Build the pipeline for the given color attachment format.
    public func configure(format: GPUTextureFormat) throws {
        if pipeline != nil && configuredFormat == format { return }

        let module = try backend.createShaderModule(wgsl: UIShader.wgsl, label: "GuavaUI")

        let bgLayout = try backend.createBindGroupLayout(entries: [
            GPUBindGroupLayoutEntry(binding: 0, visibility: [.vertex, .fragment], type: .uniformBuffer),
            GPUBindGroupLayoutEntry(binding: 1, visibility: .fragment, type: .sampledTexture),
            GPUBindGroupLayoutEntry(binding: 2, visibility: .fragment, type: .sampler),
        ])
        self.bindGroupLayout = bgLayout
        self.pipelineLayout = try backend.createPipelineLayout(bindGroupLayouts: [bgLayout])

        let layout = GPUVertexBufferLayout(arrayStride: UInt64(UIVertex.stride), attributes: [
            GPUVertexAttribute(format: .float32x2, offset: 0,  shaderLocation: 0),
            GPUVertexAttribute(format: .float32x2, offset: 8,  shaderLocation: 1),
            GPUVertexAttribute(format: .unorm8x4,  offset: 16, shaderLocation: 2),
        ])

        let pipelineDesc = GPURenderPipelineDescriptor(
            shaderModule: module,
            pipelineLayout: pipelineLayout,
            vertexEntryPoint: "vs_main",
            fragmentEntryPoint: "fs_main",
            colorFormat: format,
            topology: .triangleList,
            frontFace: .ccw,
            cullMode: .none,
            vertexBuffers: [layout],
            blend: .alphaBlending
        )
        self.pipeline = try backend.createRenderPipeline(desc: pipelineDesc)
        self.configuredFormat = format

        if alphaSampler == nil {
            self.alphaSampler = try backend.createSampler(desc: GPUSamplerDescriptor(
                magFilter: .nearest,
                minFilter: .nearest,
                mipmapFilter: .nearest
            ))
        }
        if colorSampler == nil {
            self.colorSampler = try backend.createSampler(desc: GPUSamplerDescriptor(
                magFilter: .linear,
                minFilter: .linear,
                mipmapFilter: .nearest
            ))
        }
        if uniformBuffer == nil {
            self.uniformBuffer = try backend.createBuffer(
                size: 16, usage: [.uniform, .copyDst]
            )
        }

        // Build the 1×1 solid-color fallback texture if not yet present.
        if dummyTexture == nil {
            let tex = try backend.createTexture(
                width: 1, height: 1,
                format: .rgba8Unorm,
                usage: [.textureBinding, .copyDst]
            )
            let pixels: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF]
            pixels.withUnsafeBytes { raw in
                backend.writeTexture(tex,
                                     data: raw.baseAddress!,
                                     dataSize: 4,
                                     bytesPerRow: 4,
                                     rowsPerImage: 1,
                                     width: 1, height: 1)
            }
            self.dummyTexture = tex
            self.dummyView = try tex.createView()
            self.dummyBindGroup = try makeBindGroup(view: self.dummyView!, sampling: .color)
        } else {
            // Re-create the dummy bind group against the new layout.
            self.dummyBindGroup = try makeBindGroup(view: self.dummyView!, sampling: .color)
        }

        // Re-create bind groups for any registered textures using the new layout.
        let oldTextures = textures
        textures.removeAll()
        for (id, slot) in oldTextures {
            let bg = try makeBindGroup(view: slot.view, sampling: slot.sampling)
            textures[id] = GPUTextureSlot(
                texture: slot.texture, view: slot.view,
                bindGroup: bg, sampling: slot.sampling,
                width: slot.width, height: slot.height
            )
        }
    }

    // MARK: - Texture registry

    /// Register or replace an alpha-only atlas texture under `id`. The source
    /// data is single-channel and uploaded directly as an `r8Unorm` texture.
    public func registerAlphaTexture(id: TextureID,
                                     pixels: UnsafePointer<UInt8>,
                                     width: UInt32, height: UInt32,
                                     originX: UInt32 = 0,
                                     originY: UInt32 = 0,
                                     textureWidth: UInt32? = nil,
                                     textureHeight: UInt32? = nil) throws {
        precondition(id != .none, "TextureID 0 is reserved")
        guard bindGroupLayout != nil else {
            preconditionFailure("registerAlphaTexture requires a prior configure(format:)")
        }
        let fullWidth = textureWidth ?? width
        let fullHeight = textureHeight ?? height
        // wgpu requires bytesPerRow be a multiple of 256.
        let alignedRowBytes: UInt32 = ((width + 255) / 256) * 256
        var aligned = [UInt8](repeating: 0, count: Int(alignedRowBytes * height))
        for row in 0..<Int(height) {
            let srcBase = row * Int(width)
            let dstBase = row * Int(alignedRowBytes)
            for col in 0..<Int(width) {
                aligned[dstBase + col] = pixels[srcBase + col]
            }
        }

        if let existing = textures[id],
           existing.sampling == .alphaMask,
           existing.width == fullWidth,
           existing.height == fullHeight {
            aligned.withUnsafeBytes { raw in
                backend.writeTexture(existing.texture,
                                     data: raw.baseAddress!,
                                     dataSize: aligned.count,
                                     originX: originX,
                                     originY: originY,
                                     bytesPerRow: alignedRowBytes,
                                     rowsPerImage: height,
                                     width: width, height: height)
            }
            return
        }

        let tex = try backend.createTexture(
            width: fullWidth, height: fullHeight,
            format: .r8Unorm,
            usage: [.textureBinding, .copyDst]
        )
        aligned.withUnsafeBytes { raw in
            backend.writeTexture(tex,
                                 data: raw.baseAddress!,
                                 dataSize: aligned.count,
                                 originX: originX,
                                 originY: originY,
                                 bytesPerRow: alignedRowBytes,
                                 rowsPerImage: height,
                                 width: width, height: height)
        }
        let view = try tex.createView()
        let bg = try makeBindGroup(view: view, sampling: .alphaMask)
        textures[id] = GPUTextureSlot(
            texture: tex, view: view,
            bindGroup: bg, sampling: .alphaMask,
            width: fullWidth, height: fullHeight
        )
    }

    /// Register or replace an RGBA color texture under `id`. The source data
    /// must be tightly packed RGBA8 (4 bytes per pixel, `width * 4 * height`
    /// total bytes); this is the path used by `Image` primitives.
    public func registerColorTexture(id: TextureID,
                                     pixels: UnsafePointer<UInt8>,
                                     width: UInt32, height: UInt32) throws {
        precondition(id != .none, "TextureID 0 is reserved")
        guard bindGroupLayout != nil else {
            preconditionFailure("registerColorTexture requires a prior configure(format:)")
        }
        let alignedRowBytes: UInt32 = (((width * 4) + 255) / 256) * 256
        let srcRowBytes = Int(width * 4)
        var aligned = [UInt8](repeating: 0, count: Int(alignedRowBytes * height))
        for row in 0..<Int(height) {
            let dstRowBase = row * Int(alignedRowBytes)
            let srcRowBase = row * srcRowBytes
            for col in 0..<srcRowBytes {
                aligned[dstRowBase + col] = pixels[srcRowBase + col]
            }
        }

        if let existing = textures[id],
           existing.sampling == .color,
           existing.width == width,
           existing.height == height {
            aligned.withUnsafeBytes { raw in
                backend.writeTexture(existing.texture,
                                     data: raw.baseAddress!,
                                     dataSize: aligned.count,
                                     bytesPerRow: alignedRowBytes,
                                     rowsPerImage: height,
                                     width: width, height: height)
            }
            return
        }

        let tex = try backend.createTexture(
            width: width, height: height,
            format: .rgba8Unorm,
            usage: [.textureBinding, .copyDst]
        )
        aligned.withUnsafeBytes { raw in
            backend.writeTexture(tex,
                                 data: raw.baseAddress!,
                                 dataSize: aligned.count,
                                 bytesPerRow: alignedRowBytes,
                                 rowsPerImage: height,
                                 width: width, height: height)
        }
        let view = try tex.createView()
        let bg = try makeBindGroup(view: view, sampling: .color)
        textures[id] = GPUTextureSlot(
            texture: tex, view: view,
            bindGroup: bg, sampling: .color,
            width: width, height: height
        )
    }

    // MARK: - Frame submission

    /// Issue draw calls for `list` inside an already-begun render pass.
    ///
    /// - Parameters:
    ///   - list: Source of vertices, indices and batches.
    ///   - pass: Active render pass encoder.
    ///   - viewportPx: Drawable size in pixels (used for NDC mapping and scissor).
    ///   - coordinateSpace: Layout coordinate space used by the draw list.
    public func render(list: DrawList,
                       pass: GPURenderPassEncoder,
                       viewportPx: (width: UInt32, height: UInt32),
                       coordinateSpace: (width: Float, height: Float)? = nil) throws {
        guard let pipeline,
              let uniformBuffer,
              let dummyBindGroup else {
            preconditionFailure("DrawListRenderer.render before configure(format:)")
        }
        if list.vertices.isEmpty || list.indices.isEmpty || list.batches.isEmpty {
            return
        }

        let viewport = coordinateSpace ?? (Float(viewportPx.width), Float(viewportPx.height))
        let scaleX = viewport.width > 0 ? Float(viewportPx.width) / viewport.width : 1
        let scaleY = viewport.height > 0 ? Float(viewportPx.height) / viewport.height : 1

        // 1. Upload uniforms (viewport size).
        var u: (Float, Float, Float, Float) = (viewport.width,
                                               viewport.height,
                                               0, 0)
        withUnsafePointer(to: &u) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: 16) { raw in
                backend.writeBuffer(uniformBuffer, data: raw, size: 16)
            }
        }

        // 2. Grow / upload vertex buffer.
        try ensureVertexCapacity(count: list.vertices.count)
        list.vertices.withUnsafeBufferPointer { vbuf in
            backend.writeBuffer(vertexBuffer!,
                                data: vbuf.baseAddress!,
                                size: vbuf.count * UIVertex.stride)
        }

        // 3. Grow / upload index buffer.
        try ensureIndexCapacity(count: list.indices.count)
        list.indices.withUnsafeBufferPointer { ibuf in
            backend.writeBuffer(indexBuffer!,
                                data: ibuf.baseAddress!,
                                size: ibuf.count * MemoryLayout<UInt32>.stride)
        }

        // 4. Encode draws.
        pass.setPipeline(pipeline)
        pass.setVertexBuffer(vertexBuffer!, slot: 0)
        pass.setIndexBuffer(indexBuffer!, format: .uint32)

        for batch in list.batches {
            // Bind group selection by texture.
            let bg: GPUBindGroup
            if batch.textureID == .none {
                bg = dummyBindGroup
            } else if let slot = textures[batch.textureID] {
                bg = slot.bindGroup
            } else {
                bg = dummyBindGroup
            }
            pass.setBindGroup(bg, index: 0)

            // Scissor — empty rect → skip the batch.
            if let s = batch.scissor {
                let x = max(0, Int32(floor(s.minX * scaleX)))
                let y = max(0, Int32(floor(s.minY * scaleY)))
                let maxX = max(x, Int32(ceil(s.maxX * scaleX)))
                let maxY = max(y, Int32(ceil(s.maxY * scaleY)))
                let w = max(0, maxX - x)
                let h = max(0, maxY - y)
                if w == 0 || h == 0 { continue }
                if UInt32(x) >= viewportPx.width || UInt32(y) >= viewportPx.height {
                    continue
                }
                let clampedW = min(UInt32(w), viewportPx.width  - UInt32(x))
                let clampedH = min(UInt32(h), viewportPx.height - UInt32(y))
                pass.setScissorRect(x: UInt32(x), y: UInt32(y),
                                    width: clampedW, height: clampedH)
            } else {
                pass.setScissorRect(x: 0, y: 0,
                                    width: viewportPx.width, height: viewportPx.height)
            }

            pass.drawIndexed(indexCount: batch.indexCount,
                             firstIndex: batch.indexOffset)
        }
    }

    // MARK: - Internals

    private func ensureVertexCapacity(count: Int) throws {
        let required = count * UIVertex.stride
        if let buf = vertexBuffer, vertexCapacity >= required { _ = buf; return }
        // Grow geometrically.
        var newCap = max(1024, vertexCapacity * 2)
        while newCap < required { newCap *= 2 }
        self.vertexBuffer = try backend.createBuffer(
            size: UInt64(newCap), usage: [.vertex, .copyDst]
        )
        self.vertexCapacity = newCap
    }

    private func ensureIndexCapacity(count: Int) throws {
        let required = count * MemoryLayout<UInt32>.stride
        if let buf = indexBuffer, indexCapacity >= required { _ = buf; return }
        var newCap = max(1024, indexCapacity * 2)
        while newCap < required { newCap *= 2 }
        self.indexBuffer = try backend.createBuffer(
            size: UInt64(newCap), usage: [.index, .copyDst]
        )
        self.indexCapacity = newCap
    }

    private func makeBindGroup(view: GPUTextureView, sampling: TextureSampling) throws -> GPUBindGroup {
        guard let bindGroupLayout,
              let uniformBuffer,
              let alphaSampler,
              let colorSampler else {
            preconditionFailure("missing layout/uniform/sampler — call configure first")
        }
        let sampler = switch sampling {
        case .alphaMask: alphaSampler
        case .color: colorSampler
        }
        return try backend.createBindGroup(layout: bindGroupLayout, entries: [
            GPUBindGroupEntry(binding: 0, buffer: uniformBuffer, offset: 0, size: 16),
            GPUBindGroupEntry(binding: 1, textureView: view),
            GPUBindGroupEntry(binding: 2, sampler: sampler),
        ])
    }
}
