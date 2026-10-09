// NativeRHI — submission plan and frame uploader contracts.
//
// The SubmissionPlanner turns a recorded `[RecordedCommand]` list into a
// `SubmitPlan`: one or more `PlannedSubmit`s, each carrying a linear stream of
// `PlannedCommand`s (the original passes plus synthesized barrier blocks) and
// the timeline semaphores to wait on / signal. Cross-queue ownership transfers
// are expressed as separate release submits that signal a timeline value the
// consumer waits on.

import Foundation

/// A buffer/slot pair produced by the per-frame upload ring.
public struct UploadLocation: Sendable {
    public var buffer: Buffer
    public var offset: Int

    public init(buffer: Buffer, offset: Int) {
        self.buffer = buffer
        self.offset = offset
    }
}

/// Per-slot transient storage the backend vends to the frontend. Each
/// frames-in-flight slot owns one uploader; it is reset only when that slot is
/// reused (after the GPU finished the prior frame), so allocations stay alive
/// for exactly the frame that uses them.
public protocol FrameUploader: AnyObject {
    /// Returns the uploader to a zero-used state. Called when a frame begins.
    func reset()
    /// Suballocates `data` from GPU-visible ring storage.
    func write(_ data: Data, alignment: Int) throws -> UploadLocation
}

/// A distinct immutable acquisition ticket. The borrowed `texture` is valid
/// through this frame; retaining a ticket does not make it a persistent image.
/// Backend texture IDs may be recycled, but old tickets never become current.
public final class SwapchainImage: Equatable, Sendable {
    public static func == (lhs: SwapchainImage, rhs: SwapchainImage) -> Bool { lhs === rhs }
    public let swapchain: Swapchain
    public let generation: UInt64
    public let texture: Texture
    public let width: Int
    public let height: Int

    public init(swapchain: Swapchain, generation: UInt64, texture: Texture, width: Int, height: Int) {
        self.swapchain = swapchain
        self.generation = generation
        self.texture = texture
        self.width = width
        self.height = height
    }
}

/// One linear command stream for a single queue submission. Barriers are
/// represented as explicit `.barriers` blocks interspersed with passes.
public enum PlannedCommand: Sendable {
    case accelerationStructureBuild(AccelerationStructureBuild)
    case renderPass(RenderPassRecord)
    case computePass(ComputePassRecord)
    case copyPass(CopyPassRecord)
    case barriers([BarrierCommand])
}

public struct PlannedSubmit: Sendable {
    public var queue: QueueClass
    public var commands: [PlannedCommand]
    public var waitSemaphores: [TimelineSemaphore]
    public var signalSemaphores: [TimelineSemaphore]

    public init(
        queue: QueueClass,
        commands: [PlannedCommand],
        waitSemaphores: [TimelineSemaphore] = [],
        signalSemaphores: [TimelineSemaphore] = []
    ) {
        self.queue = queue
        self.commands = commands
        self.waitSemaphores = waitSemaphores
        self.signalSemaphores = signalSemaphores
    }
}

/// The complete result of planning one frontend submission. It is ordered for
/// execution: release submits (cross-queue) first, then the primary submit.
public struct SubmitPlan: Sendable {
    public var submits: [PlannedSubmit]

    public init(submits: [PlannedSubmit] = []) {
        self.submits = submits
    }
}
