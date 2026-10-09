// NativeRHI — resource state tracking and automatic barrier synthesis.
//
// Direct Swift port of state_tracker.zig. The tracker stores the last known
// usage state of each tracked resource and emits a barrier whenever a command
// requires a different state. Repeated transitions of the same resource within
// one commit window are merged.

import Foundation

public enum ResourceKind: UInt8, Hashable, Sendable {
    case buffer
    case texture
    case accelerationStructure
}

public struct ResourceRef: Hashable, Sendable {
    public var kind: ResourceKind
    public var id: UInt32
    public var subresourceBase: UInt16
    public var subresourceCount: UInt16

    public init(kind: ResourceKind, id: UInt32, subresourceBase: UInt16 = 0, subresourceCount: UInt16 = 1) {
        self.kind = kind
        self.id = id
        self.subresourceBase = subresourceBase
        self.subresourceCount = subresourceCount
    }
}

public struct Barrier: Sendable {
    public var resource: ResourceRef
    public var before: ResourceState
    public var after: ResourceState
    public var crossQueue: Bool

    public init(resource: ResourceRef, before: ResourceState, after: ResourceState, crossQueue: Bool = false) {
        self.resource = resource
        self.before = before
        self.after = after
        self.crossQueue = crossQueue
    }
}

struct StateTracker {
    private var currentStates: [ResourceRef: ResourceState] = [:]
    private(set) var pendingBarriers: [Barrier] = []

    mutating func clear() {
        currentStates.removeAll(keepingCapacity: true)
        pendingBarriers.removeAll(keepingCapacity: true)
    }

    mutating func setInitialState(_ resource: ResourceRef, _ state: ResourceState) {
        currentStates[resource] = state
    }

    mutating func setCurrentState(_ resource: ResourceRef, _ state: ResourceState) {
        currentStates[resource] = state
    }

    func currentState(_ resource: ResourceRef) -> ResourceState {
        currentStates[resource] ?? []
    }

    mutating func removeResource(_ resource: ResourceRef) {
        currentStates.removeValue(forKey: resource)
    }

    /// Records a required state. If it differs from the current state, a
    /// barrier is queued and the tracked state is advanced immediately.
    mutating func requireState(_ resource: ResourceRef, _ desired: ResourceState) {
        let current = currentStates[resource] ?? []
        if current == desired { return }
        pendingBarriers.append(Barrier(resource: resource, before: current, after: desired))
        currentStates[resource] = desired
    }

    /// Drains the queued barriers, merging multiple transitions of the same
    /// resource into a single barrier whose destination state is the union.
    mutating func commitBarriers() -> [Barrier] {
        if pendingBarriers.isEmpty { return [] }

        var merged: [ResourceRef: Barrier] = [:]
        for barrier in pendingBarriers {
            if let existing = merged[barrier.resource] {
                merged[barrier.resource]?.after = existing.after.union(barrier.after)
            } else {
                merged[barrier.resource] = barrier
            }
        }
        pendingBarriers.removeAll(keepingCapacity: true)
        return Array(merged.values)
    }
}
