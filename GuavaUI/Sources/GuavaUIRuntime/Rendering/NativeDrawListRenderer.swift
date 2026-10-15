import Foundation
import GuavaUICore
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
    /// Set when this recording carried atlas uploads; cleared on successful
    /// submission so abandoned recordings keep their pixels queued.
    let atlasCommit: NativeUIAtlasCommit?
    var presentationCommit: (() -> Void)? = nil

    /// Acknowledge this recording only after its commands were submitted.
    /// Ownership and update sequences travel with the token, so the caller
    /// does not need to retain or select the renderer that created it.
    public func didSubmit() {
        commits.forEach { $0.slot.commit(through: $0.sequence) }
        atlasCommit?.commit()
        presentationCommit?()
    }
}

/// Acknowledges one recording's atlas uploads.
struct NativeUIAtlasCommit {
    let store: NativeUITextureStore
    let sequence: UInt64

    func commit() { store.commitAtlasUploads(through: sequence) }
}

private struct NativeUIBatch {
    var indices: DrawBatch
    var scissor: ScissorRect
    let bindings: BindingSet
    /// True when this batch's scissor actually clips geometry extending past it
    /// (e.g. a parent container clip). Such batches must keep their own scissor
    /// and therefore cannot be folded into a merged draw.
    let reliesOnClip: Bool
    /// A frosted panel starts here: the frame behind it is blurred before this
    /// batch draws, so it can never be merged into the draw behind it either.
    var backdrop: UIBackdrop? { indices.backdrop }
}

/// Consumes GuavaUI geometry on a caller-owned NativeRHI frame and command list.
/// Call methods serially per renderer. Siblings share immutable GPU resources;
/// their frame uploads and pending-patch acknowledgements remain independent.
public final class NativeDrawListRenderer {
    private let device: Device
    private let shaders: NativeUIShaderResources
    /// Optional: a backend without the offline backdrop artifact (DXIL is not
    /// generated here yet) keeps every panel, they just lose the frost.
    private let backdropShaders: NativeUIBackdropShaders?
    let textureStore: NativeUITextureStore
    private var geometry: NativeUIGeometry?
    private var pipeline: NativeUIPipeline?
    private var backdropPass: NativeUIBackdropPass?
    /// The reveal run whose frame is already retained, so a long reveal
    /// composites one frame instead of re-retaining a half-revealed one.
    private struct FrameExtent: Equatable {
        let pixels: SIMD2<Int>
        let logical: SIMD2<Float>
    }
    private struct RetainedReveal {
        let sequence: UInt64
        let texture: Texture?
        let extent: FrameExtent
    }
    private var retainedReveal: RetainedReveal?
    private var lastFrameExtent: FrameExtent?

    public init(device: Device) throws {
        self.device = device
        shaders = try NativeUIShaderResources(device: device)
        backdropShaders = try? NativeUIBackdropShaders(device: device)
        textureStore = try NativeUITextureStore(device: device, shaders: shaders)
    }
    private init(device: Device, shaders: NativeUIShaderResources,
                 backdropShaders: NativeUIBackdropShaders?) throws {
        self.device = device; self.shaders = shaders; self.backdropShaders = backdropShaders
        textureStore = try NativeUITextureStore(device: device, shaders: shaders)
    }

    public func configure(format: TextureFormat, sampleCount: Int = 1) throws {
        if pipeline?.format == format && pipeline?.samples == sampleCount { return }
        pipeline = try NativeUIPipeline(shaders: shaders, format: format, samples: sampleCount)
        backdropPass = try backdropShaders.map {
            try NativeUIBackdropPass(device: device, shaders: $0, format: format, samples: sampleCount)
        }
        retainedReveal = nil
        lastFrameExtent = nil
    }

    public func makeSibling(format: TextureFormat, sampleCount: Int = 1) throws -> NativeDrawListRenderer {
        let sibling = try NativeDrawListRenderer(device: device, shaders: shaders,
                                                backdropShaders: backdropShaders)
        try sibling.configure(format: format, sampleCount: sampleCount)
        try sibling.synchronizeTextures(from: self)
        return sibling
    }

    /// Whether frosted panels can be drawn: false on a backend whose offline
    /// backdrop artifact is missing. Panels still render, without the frost.
    public var supportsBackdrop: Bool { backdropPass != nil }

    /// Hands an owned frame to the swapchain, which is a render target only and
    /// must never be sampled by a backdrop. No-op without `supportsBackdrop`;
    /// a caller that switched its frame into an owned texture must branch on it.
    public func recordBlit(source: Texture, into commands: CommandBuffer,
                           target: RenderColorTarget, size: SIMD2<Int>) throws {
        try backdropPass?.recordBlit(source: source, into: commands, target: target, size: size)
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

    /// - Parameter backdropSource: the texture holding this frame so far, when
    ///   the caller renders into one it owns. `nil` disables frosted panels: the
    ///   blur needs to sample the frame, and a swapchain image cannot be.
    public func record(list: DrawList, into commands: CommandBuffer, target: RenderColorTarget,
        viewport: NativeUIViewport, backdropSource: Texture? = nil) throws -> NativeUIDrawFrame {
        guard let pipeline else { throw RHIError.invalidArgument("configure the native UI renderer before recording") }
        try viewport.validate()
        if geometry?.matches(list) != true { geometry = try NativeUIGeometry(validating: list) }
        let clipReliance = geometry!.reliesOnClip
        // A reveal shows this frame through the previous one, so the previous
        // frame has to be retained before a single pixel of this one is drawn.
        // `backdropSource` is nil on a backend without the backdrop program and
        // on a frame drawn straight into a swapchain image; both cannot sample
        // what they just drew, so the request is simply dropped.
        var retained: Texture?
        var nextReveal: RetainedReveal?
        let extent = FrameExtent(pixels: viewport.pixels, logical: viewport.logical)
        if let backdropPass, let backdropSource, let reveal = list.reveal {
            if retainedReveal?.sequence != reveal.sequence {
                if lastFrameExtent == extent {
                    retained = try backdropPass.recordRevealCapture(source: backdropSource,
                        viewport: viewport, into: commands)
                }
            } else if retainedReveal?.extent == extent {
                retained = retainedReveal?.texture
            }
            // A resized target has no previous image of the new extent. Snap
            // this run rather than sampling an old-sized frame or restarting
            // halfway through the reveal.
            nextReveal = RetainedReveal(sequence: reveal.sequence, texture: retained,
                extent: extent)
        }
        try textureStore.prepareAssets(list.resources)
        var statistics = NativeUIDrawStatistics()
        statistics.vertices = list.vertices.count; statistics.indices = list.indices.count
        let slots = [textureStore.fallback] + textureStore.textures.values
        var uploads: [TextureBufferUpload] = [], commits: [NativeUITextureCommit] = []
        // Atlas placements upload first; they are one-shot and consumed here so
        // steady-state frames perform no texture uploads.
        let atlasUploads = try textureStore.buildAtlasUploads()
        uploads.append(contentsOf: atlasUploads.uploads)
        statistics.textureUploads += atlasUploads.uploads.count
        statistics.textureUploadBytes += atlasUploads.bytes
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
            // Atlased image batches are rewritten so their UVs address the shared
            // atlas texture; this keeps the draw list geometry (and thus the
            // production call sites that build it) unchanged. When no asset is
            // atlased the original vertex buffer is uploaded untouched.
            if textureStore.hasAtlasedPlacements {
                let remapped = textureStore.remapAtlasUVs(list: list)
                vertices = try remapped.withUnsafeBytes { try device.uploadTransient($0) }
            } else {
                vertices = try list.vertices.withUnsafeBytes { try device.uploadTransient($0) }
            }
            indices = try list.indices.withUnsafeBytes { try device.uploadTransient($0) }
            for (index, batch) in list.batches.enumerated() {
                guard batch.indexCount > 0, let scissor = try viewport.scissor(batch.scissor) else { continue }
                let bindings = textureStore.bindingSet(for: batch.textureID)
                let reliesOnClip = clipReliance[index]
                draws.append(NativeUIBatch(indices: batch, scissor: scissor, bindings: bindings, reliesOnClip: reliesOnClip))
            }
        }
        // Collapse consecutive batches that share a binding set into a single
        // draw call. This folds the 96 distinct image textures (now packed into
        // one atlas) and all solid-color batches (sharing the fallback) into a
        // handful of draws, cutting Metal encode/replay cost.
        let coalesced = coalesceDraws(draws)
        // Append only after all validation, allocations and bindings succeed.
        if !uploads.isEmpty { commands.copyPass { pass in uploads.forEach { pass.uploadBufferToTexture($0) } } }
        // A frosted panel cannot be drawn in the same pass that captures its
        // backdrop, so the frame is recorded as segments split around them.
        var segmentStart = 0
        var pending: NativeUIBackdropComposite?
        var frosted = 0
        for (index, draw) in coalesced.enumerated() {
            guard let backdrop = draw.backdrop, let backdropPass, let backdropSource else { continue }
            try recordSegment(coalesced[segmentStart..<index], composite: pending,
                loadAction: segmentStart == 0 ? target.loadAction : .load, isFirst: segmentStart == 0,
                into: commands, target: target, viewport: viewport, pipeline: pipeline,
                vertices: vertices, indices: indices, backdropPass: backdropPass)
            segmentStart = index
            pending = try backdropPass.record(backdrop, source: backdropSource,
                frame: viewport.pixels, logical: viewport.logical, into: commands)
            if pending != nil { frosted += 1 }
        }
        try recordSegment(coalesced[segmentStart...], composite: pending,
            loadAction: segmentStart == 0 ? target.loadAction : .load, isFirst: segmentStart == 0,
            into: commands, target: target, viewport: viewport, pipeline: pipeline,
            vertices: vertices, indices: indices, backdropPass: backdropPass)
        // Last, so the reveal covers everything the new frame drew — including
        // any frosted panel that opened in the same frame.
        if let backdropPass, let retained, let reveal = list.reveal {
            var compositeTarget = target
            compositeTarget.loadAction = .load
            compositeTarget.store = true
            try commands.renderPass(
                descriptor: RenderPassDescriptor(colorTargets: [compositeTarget], label: "ui-reveal")) { pass in
                try backdropPass.drawReveal(reveal, source: retained, viewport: viewport, in: &pass)
            }
        }
        statistics.drawCalls = coalesced.count + frosted + (retained == nil ? 0 : 1)
        var frame = NativeUIDrawFrame(statistics: statistics, pipeline: pipeline, textures: slots, commits: commits,
            atlasCommit: atlasUploads.sequence == 0 ? nil
                : NativeUIAtlasCommit(store: textureStore, sequence: atlasUploads.sequence))
        frame.presentationCommit = { [weak self] in
            self?.retainedReveal = nextReveal
            self?.lastFrameExtent = extent
            if nextReveal == nil { self?.backdropPass?.clearRevealCapture() }
        }
        return frame
    }

    /// One slice of the frame between two backdrop captures.
    private func recordSegment(_ draws: ArraySlice<NativeUIBatch>,
        composite: NativeUIBackdropComposite?, loadAction: ColorLoadAction, isFirst: Bool,
        into commands: CommandBuffer, target: RenderColorTarget, viewport: NativeUIViewport,
        pipeline: NativeUIPipeline, vertices: UploadLocation?, indices: UploadLocation?,
        backdropPass: NativeUIBackdropPass?) throws {
        // The first segment runs even with nothing to draw: it carries the
        // clear, and an empty frame still has to show the clear colour.
        guard composite != nil || !draws.isEmpty || isFirst else { return }
        var colorTarget = target
        colorTarget.loadAction = loadAction
        // Keep the multisampled attachment: every segment after the first
        // resumes it with `.load`, and discarding it would drop the geometry
        // those segments are meant to draw over.
        colorTarget.store = true
        try commands.renderPass(descriptor: RenderPassDescriptor(colorTargets: [colorTarget], label: "ui-segment")) { pass in
            pass.setViewport(Viewport(width: Double(viewport.pixels.x), height: Double(viewport.pixels.y)))
            if let composite, let backdropPass {
                try backdropPass.draw(composite, in: &pass)
            }
            guard let vertices, let indices, !draws.isEmpty else { return }
            pass.setPipeline(pipeline.handle)
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

    /// Merge consecutive draws that bind the same set into one draw covering
    /// their contiguous index range. The merged scissor is the union of the two
    /// so no geometry is accidentally clipped.
    private func coalesceDraws(_ draws: [NativeUIBatch]) -> [NativeUIBatch] {
        var result: [NativeUIBatch] = []
        for draw in draws {
            if let last = result.last,
               last.bindings == draw.bindings,
               !last.reliesOnClip, !draw.reliesOnClip,
               // A frosted panel needs a pass boundary in front of it, so it
               // stays its own draw even when it shares a binding set.
               draw.backdrop == nil,
               // Nothing may sit between the two index ranges: batches skipped
               // above (clipped away) must stay undrawn, and a gap would
               // resurrect their geometry inside the merged range.
               last.indices.indexOffset + last.indices.indexCount == draw.indices.indexOffset {
                // Batches are appended in draw-list order with contiguous index
                // ranges, so consecutive same-binding draws can share one draw
                // call. The union scissor keeps every primitive unclipped.
                let mergedCount = Int(draw.indices.indexOffset + draw.indices.indexCount) - Int(last.indices.indexOffset)
                var mergedScissor = last.scissor
                mergedScissor.x = min(last.scissor.x, draw.scissor.x)
                mergedScissor.y = min(last.scissor.y, draw.scissor.y)
                mergedScissor.width = max(last.scissor.x + last.scissor.width, draw.scissor.x + draw.scissor.width) - mergedScissor.x
                mergedScissor.height = max(last.scissor.y + last.scissor.height, draw.scissor.y + draw.scissor.height) - mergedScissor.y
                var merged = last
                merged.indices.indexCount = UInt32(mergedCount)
                merged.scissor = mergedScissor
                result[result.count - 1] = merged
            } else {
                result.append(draw)
            }
        }
        return result
    }
}
