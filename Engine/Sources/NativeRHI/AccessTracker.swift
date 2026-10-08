// NativeRHI — orthogonal access-dependency (hazard) tracking.
//
// This layer is deliberately separate from StateTracker:
//   * StateTracker answers "what state / image layout is a resource in?" and
//     emits a transition barrier when the STATE changes (layout, binding kind).
//   * AccessTracker answers "which prior memory accesses must complete before
//     this one?" and emits an ordering dependency (RAW / WAR / WAW) even when
//     the state is unchanged — e.g. two consecutive storage writes, or a write
//     followed by a read of the same unordered-access resource.
//
// The SubmissionPlanner runs BOTH; state transitions and access ordering are
// orthogonal. Backends that order within an encoder (Metal tracked resources)
// may consume the ordering as a no-op; backends that need explicit barriers
// (Vulkan) map it to a pipeline barrier; cross-queue hazards ride the
// release/acquire timeline path.

import Foundation

// MARK: - Access vocabulary

/// Read or write.
enum AccessKind: Hashable, Sendable {
    case read
    case write
}

/// Pipeline stages at which an access can occur. An OptionSet so a resource
/// bound to several shader stages (e.g. vertex + fragment) is expressible.
struct AccessStage: OptionSet, Hashable, Sendable {
    let rawValue: UInt8
    init(rawValue: UInt8) { self.rawValue = rawValue }

    static let vertex = AccessStage(rawValue: 1 << 0)
    static let fragment = AccessStage(rawValue: 1 << 1)
    static let compute = AccessStage(rawValue: 1 << 2)
    static let task = AccessStage(rawValue: 1 << 4)
    static let mesh = AccessStage(rawValue: 1 << 5)
    static let transfer = AccessStage(rawValue: 1 << 3)

    /// Maps a shader stage to the matching access stage.
    static func of(_ stage: ShaderStage) -> AccessStage {
        switch stage {
        case .vertex: return .vertex
        case .fragment: return .fragment
        case .compute: return .compute
        case .task: return .task
        case .mesh: return .mesh
        }
    }
}

/// A half-open byte interval within a buffer. A `.whole` range (or a nil range
/// on an access) spans the entire resource.
struct BufferRange: Hashable, Sendable {
    var offset: Int
    var size: Int

    init(offset: Int = 0, size: Int = Int.max) {
        self.offset = offset
        self.size = size
    }

    static let whole = BufferRange()

    /// Whether two half-open intervals overlap.
    func overlaps(_ other: BufferRange) -> Bool {
        switch (self.size == Int.max, other.size == Int.max) {
        case (true, true):
            return true
        case (true, false):
            return other.offset >= self.offset
        case (false, true):
            return self.offset >= other.offset
        case (false, false):
            let (aEnd, aOverflow) = self.offset.addingReportingOverflow(self.size)
            let (bEnd, bOverflow) = other.offset.addingReportingOverflow(other.size)
            if aOverflow || bOverflow { return true }
            return aEnd > other.offset && bEnd > self.offset
        }
    }
}

/// One observed access to a resource.
struct ResourceAccess: Sendable {
    var resource: ResourceRef
    var kind: AccessKind
    var stage: AccessStage
    var range: BufferRange?
    /// True for color/depth attachment writes. These are ordered by the render
    /// pass boundary (load/store), so a same-state attachment→attachment hazard
    /// does not require an extra barrier. Storage/unordered accesses are not
    /// attachment-ordered and still need explicit ordering.
    var isAttachment: Bool

    init(resource: ResourceRef, kind: AccessKind, stage: AccessStage,
         range: BufferRange? = nil, isAttachment: Bool = false) {
        self.resource = resource
        self.kind = kind
        self.stage = stage
        self.range = range
        self.isAttachment = isAttachment
    }
}

// MARK: - Hazard

/// An ordering dependency between a prior access and the current access.
struct Hazard: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case readAfterWrite   // RAW
        case writeAfterRead   // WAR
        case writeAfterWrite  // WAW
    }

    var resource: ResourceRef
    var kind: Kind
    var sourceStage: AccessStage
    var destinationStage: AccessStage
    var sourceQueue: QueueClass
    var destinationQueue: QueueClass
    var range: BufferRange?
}

// MARK: - Tracker

/// Per-resource active access window: the last write plus the reads since it.
final class AccessTracker {
    private struct Record: Sendable {
        let kind: AccessKind
        let stage: AccessStage
        let queue: QueueClass
        let range: BufferRange?
    }

    private struct Memory {
        var lastWrite: Record?
        var reads: [Record] = []
    }

    private var memories: [ResourceRef: Memory] = [:]
    /// All hazards produced since the last `reset` (diagnostic / test surface).
    private(set) var observedHazards: [Hazard] = []

    init() {}

    func reset() {
        memories.removeAll(keepingCapacity: true)
        observedHazards.removeAll(keepingCapacity: true)
    }

    func removeResource(_ resource: ResourceRef) {
        memories.removeValue(forKey: resource)
    }

    /// Records an access and returns the hazards against prior overlapping
    /// accesses. The ordering window is then pruned: a new write clears the
    /// reads and becomes the new last write.
    @discardableResult
    func observe(_ access: ResourceAccess, on queue: QueueClass) -> [Hazard] {
        var memory = memories[access.resource] ?? Memory()
        var hazards: [Hazard] = []
        let range = access.range ?? .whole

        switch access.kind {
        case .read:
            if let write = memory.lastWrite, Self.overlaps(write.range, range) {
                hazards.append(Hazard(
                    resource: access.resource, kind: .readAfterWrite,
                    sourceStage: write.stage, destinationStage: access.stage,
                    sourceQueue: write.queue, destinationQueue: queue, range: access.range))
            }
            memory.reads.append(Record(kind: .read, stage: access.stage, queue: queue, range: access.range))

        case .write:
            if let write = memory.lastWrite, Self.overlaps(write.range, range) {
                hazards.append(Hazard(
                    resource: access.resource, kind: .writeAfterWrite,
                    sourceStage: write.stage, destinationStage: access.stage,
                    sourceQueue: write.queue, destinationQueue: queue, range: access.range))
            }
            for read in memory.reads where Self.overlaps(read.range, range) {
                hazards.append(Hazard(
                    resource: access.resource, kind: .writeAfterRead,
                    sourceStage: read.stage, destinationStage: access.stage,
                    sourceQueue: read.queue, destinationQueue: queue, range: access.range))
            }
            memory.lastWrite = Record(kind: .write, stage: access.stage, queue: queue, range: access.range)
            memory.reads = []
        }

        memories[access.resource] = memory
        observedHazards.append(contentsOf: hazards)
        return hazards
    }

    private static func overlaps(_ prior: BufferRange?, _ current: BufferRange) -> Bool {
        (prior ?? .whole).overlaps(current)
    }
}
