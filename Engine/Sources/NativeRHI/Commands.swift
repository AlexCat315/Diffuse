// NativeRHI — recorded command model.
//
// The Zig original serialized commands into a byte stream (opcode + packed
// structs) that was decoded twice — once by the frontend planner and again by
// the C bridge. Swift has no FFI boundary between frontend and backend, so a
// command buffer is a typed list of `RecordedCommand` values. Passes are
// scoped records with their own body arrays, which makes unterminated or
// mis-nested passes unrepresentable.

import Foundation
import simd

// MARK: - Render pass targets

public enum ColorLoadAction: Sendable {
    case clear(SIMD4<Float>)
    case load
    case dontCare
}

public enum DepthLoadAction: Sendable {
    case clear(Double)
    case load
    case dontCare
}

public struct RenderColorTarget: Sendable {
    /// Resolve the multisampled attachment into this single-sample color target.
    public var resolveTexture: Texture? = nil
    public var texture: Texture
    public var loadAction: ColorLoadAction
    public var store: Bool

    public init(texture: Texture, loadAction: ColorLoadAction = .dontCare, store: Bool = true) {
        self.texture = texture
        self.loadAction = loadAction
        self.store = store
    }
}

public struct RenderDepthTarget: Sendable {
    public var texture: Texture
    public var loadAction: DepthLoadAction
    public var store: Bool

    public init(texture: Texture, loadAction: DepthLoadAction = .clear(1.0), store: Bool = true) {
        self.texture = texture
        self.loadAction = loadAction
        self.store = store
    }
}

public struct RenderPassDescriptor: Sendable {
    public var colorTargets: [RenderColorTarget]
    public var depthTarget: RenderDepthTarget?

    public init(colorTargets: [RenderColorTarget], depthTarget: RenderDepthTarget? = nil) {
        self.colorTargets = colorTargets
        self.depthTarget = depthTarget
    }
}

public struct Viewport: Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var minDepth: Double
    public var maxDepth: Double

    public init(x: Double = 0, y: Double = 0, width: Double, height: Double, minDepth: Double = 0, maxDepth: Double = 1) {
        self.x = x; self.y = y; self.width = width; self.height = height
        self.minDepth = minDepth; self.maxDepth = maxDepth
    }
}

public struct ScissorRect: Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int = 0, y: Int = 0, width: Int, height: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public struct DrawIndexedArguments: Sendable {
    public var indexCount: Int
    public var instanceCount: Int
    public var firstIndex: Int
    public var vertexOffset: Int
    public var firstInstance: Int

    public init(
        indexCount: Int,
        instanceCount: Int = 1,
        firstIndex: Int = 0,
        vertexOffset: Int = 0,
        firstInstance: Int = 0
    ) {
        self.indexCount = indexCount
        self.instanceCount = instanceCount
        self.firstIndex = firstIndex
        self.vertexOffset = vertexOffset
        self.firstInstance = firstInstance
    }
}

// MARK: - Per-pass commands

public enum RenderCommand: Sendable {
    case setPipeline(GraphicsPipeline)
    case setMeshPipeline(MeshPipeline)
    case drawMeshTasks(ThreadgroupSize)
    case setBindingSet(slot: UInt32, set: BindingSet)
    case setVertexBuffer(slot: UInt32, buffer: Buffer, offset: Int)
    case setIndexBuffer(buffer: Buffer, offset: Int, type: IndexType)
    /// Small constants copied into per-frame upload storage and bound at the
    /// given argument index (Metal push constants model).
    case pushConstant(stage: ShaderStage, slot: UInt32, data: Data)
    case setViewport(Viewport)
    case setScissor(ScissorRect)
    case draw(vertexCount: Int, instanceCount: Int, firstVertex: Int, firstInstance: Int)
    case drawIndexed(DrawIndexedArguments)
    case drawIndirect(buffer: Buffer, offset: Int, drawCount: Int)
}

public enum ComputeCommand: Sendable {
    case setPipeline(ComputePipeline)
    case setBindingSet(slot: UInt32, set: BindingSet)
    case pushConstant(stage: ShaderStage, slot: UInt32, data: Data)
    case dispatch(groupsX: Int, groupsY: Int, groupsZ: Int)
    case dispatchIndirect(buffer: Buffer, offset: Int)
}

public enum CopyCommand: Sendable {
    /// Top-left base-level copy between distinct single-sample 2D color textures.
    case copyTexture(src: Texture, dst: Texture, width: Int, height: Int)
    case copyBuffer(src: Buffer, srcOffset: Int, dst: Buffer, dstOffset: Int, size: Int)
    case copyBufferToTexture(TextureBufferUpload)
    case copyTextureToBuffer(
        texture: Texture, width: Int, height: Int,
        buffer: Buffer, offset: Int, bytesPerRow: Int
    )
}

public struct BarrierCommand: Sendable {
    public var resource: ResourceRef
    public var sourceState: ResourceState
    public var destinationState: ResourceState
    public var syncAction: BarrierSyncAction
    public var passScope: BarrierPassScope
    public var sourceQueue: QueueClass
    public var destinationQueue: QueueClass

    public init(
        resource: ResourceRef,
        sourceState: ResourceState,
        destinationState: ResourceState,
        syncAction: BarrierSyncAction = .full,
        passScope: BarrierPassScope = .outsidePass,
        sourceQueue: QueueClass = .graphics,
        destinationQueue: QueueClass = .graphics
    ) {
        self.resource = resource
        self.sourceState = sourceState
        self.destinationState = destinationState
        self.syncAction = syncAction
        self.passScope = passScope
        self.sourceQueue = sourceQueue
        self.destinationQueue = destinationQueue
    }
}

public struct RenderPassRecord: Sendable {
    public var descriptor: RenderPassDescriptor
    public var body: [RenderCommand]
}

public struct ComputePassRecord: Sendable {
    public var body: [ComputeCommand]
}

public struct CopyPassRecord: Sendable {
    public var body: [CopyCommand]
}

public enum RecordedCommand: Sendable {
    case accelerationStructureBuild(AccelerationStructureBuild)
    case renderPass(RenderPassRecord)
    case computePass(ComputePassRecord)
    case copyPass(CopyPassRecord)
    case barrier(BarrierCommand)
}

// MARK: - Recorders

public struct RenderPassEncoder {
    fileprivate(set) var body: [RenderCommand] = []

    public mutating func setMeshPipeline(_ pipeline: MeshPipeline) {
        body.append(.setMeshPipeline(pipeline))
    }

    public mutating func drawMeshTasks(x: Int, y: Int = 1, z: Int = 1) {
        body.append(.drawMeshTasks(ThreadgroupSize(x: x, y: y, z: z)))
    }

    public mutating func setPipeline(_ pipeline: GraphicsPipeline) {
        body.append(.setPipeline(pipeline))
    }

    public mutating func setBindingSet(_ set: BindingSet, slot: UInt32 = 0) {
        body.append(.setBindingSet(slot: slot, set: set))
    }

    public mutating func setVertexBuffer(_ buffer: Buffer, offset: Int = 0, slot: UInt32 = 0) {
        body.append(.setVertexBuffer(slot: slot, buffer: buffer, offset: offset))
    }

    public mutating func setIndexBuffer(_ buffer: Buffer, offset: Int = 0, type: IndexType) {
        body.append(.setIndexBuffer(buffer: buffer, offset: offset, type: type))
    }

    public mutating func pushConstant<T>(stage: ShaderStage, slot: UInt32, value: T) {
        withUnsafeBytes(of: value) { bytes in
            body.append(.pushConstant(stage: stage, slot: slot, data: Data(bytes)))
        }
    }

    public mutating func setViewport(_ viewport: Viewport) {
        body.append(.setViewport(viewport))
    }

    public mutating func setScissor(_ scissor: ScissorRect) {
        body.append(.setScissor(scissor))
    }

    public mutating func draw(vertexCount: Int, instanceCount: Int = 1, firstVertex: Int = 0, firstInstance: Int = 0) {
        body.append(.draw(vertexCount: vertexCount, instanceCount: instanceCount, firstVertex: firstVertex, firstInstance: firstInstance))
    }

    public mutating func drawIndexed(_ args: DrawIndexedArguments) {
        body.append(.drawIndexed(args))
    }

    public mutating func drawIndirect(buffer: Buffer, offset: Int = 0, drawCount: Int = 1) {
        body.append(.drawIndirect(buffer: buffer, offset: offset, drawCount: drawCount))
    }
}

public struct ComputePassEncoder {
    fileprivate(set) var body: [ComputeCommand] = []

    public mutating func setPipeline(_ pipeline: ComputePipeline) {
        body.append(.setPipeline(pipeline))
    }

    public mutating func setBindingSet(_ set: BindingSet, slot: UInt32 = 0) {
        body.append(.setBindingSet(slot: slot, set: set))
    }

    public mutating func pushConstant<T>(stage: ShaderStage = .compute, slot: UInt32, value: T) {
        withUnsafeBytes(of: value) { bytes in
            body.append(.pushConstant(stage: stage, slot: slot, data: Data(bytes)))
        }
    }

    /// Dispatches workgroups; each group uses the shader module's local size.
    public mutating func dispatch(groupsX: Int, groupsY: Int = 1, groupsZ: Int = 1) {
        body.append(.dispatch(groupsX: groupsX, groupsY: groupsY, groupsZ: groupsZ))
    }

    public mutating func dispatchIndirect(buffer: Buffer, offset: Int = 0) {
        body.append(.dispatchIndirect(buffer: buffer, offset: offset))
    }
}

public struct CopyPassEncoder {
    fileprivate(set) var body: [CopyCommand] = []

    public mutating func copyTexture(src: Texture, dst: Texture, width: Int, height: Int) {
        body.append(.copyTexture(src: src, dst: dst, width: width, height: height))
    }

    public mutating func copyBuffer(src: Buffer, srcOffset: Int = 0, dst: Buffer, dstOffset: Int = 0, size: Int) {
        body.append(.copyBuffer(src: src, srcOffset: srcOffset, dst: dst, dstOffset: dstOffset, size: size))
    }

    public mutating func uploadBufferToTexture(_ upload: TextureBufferUpload) {
        body.append(.copyBufferToTexture(upload))
    }

    public mutating func copyTextureToBuffer(
        texture: Texture,
        width: Int,
        height: Int,
        buffer: Buffer,
        offset: Int = 0,
        bytesPerRow: Int
    ) {
        body.append(.copyTextureToBuffer(
            texture: texture, width: width, height: height,
            buffer: buffer, offset: offset, bytesPerRow: bytesPerRow
        ))
    }
}

/// A reusable, resettable list of recorded commands.
public final class CommandBuffer {
    public private(set) var commands: [RecordedCommand] = []

    public init() {}

    func buildAccelerationStructure(_ build: AccelerationStructureBuild) {
        commands.append(.accelerationStructureBuild(build))
    }

    public func reset() {
        commands.removeAll(keepingCapacity: true)
    }

    public var isEmpty: Bool { commands.isEmpty }

    public func renderPass(
        descriptor: RenderPassDescriptor,
        _ body: (inout RenderPassEncoder) throws -> Void
    ) rethrows {
        var encoder = RenderPassEncoder()
        try body(&encoder)
        commands.append(.renderPass(RenderPassRecord(descriptor: descriptor, body: encoder.body)))
    }

    public func computePass(_ body: (inout ComputePassEncoder) throws -> Void) rethrows {
        var encoder = ComputePassEncoder()
        try body(&encoder)
        commands.append(.computePass(ComputePassRecord(body: encoder.body)))
    }

    public func copyPass(_ body: (inout CopyPassEncoder) throws -> Void) rethrows {
        var encoder = CopyPassEncoder()
        try body(&encoder)
        commands.append(.copyPass(CopyPassRecord(body: encoder.body)))
    }

    public func barrier(_ barrier: BarrierCommand) {
        commands.append(.barrier(barrier))
    }
}
