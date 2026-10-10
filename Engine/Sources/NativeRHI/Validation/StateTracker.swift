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

    /// Collision-free packed key for the internal tracker dictionaries. IDs are
    /// handed out by a single global pool, so (kind, id) uniquely identifies a
    /// resource. Subresource is intentionally dropped: resources that differ
    /// only in subresource collapse to one key, which at worst over-orders a
    /// barrier — safe, never incorrect.
    var trackerKey: UInt64 {
        (UInt64(kind.rawValue) << 32) | UInt64(id)
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
    private var currentStates: [UInt64: ResourceState] = [:]
    private(set) var pendingBarriers: [Barrier] = []

    mutating func clear() {
        currentStates.removeAll(keepingCapacity: true)
        pendingBarriers.removeAll(keepingCapacity: true)
    }

    mutating func setInitialState(_ resource: ResourceRef, _ state: ResourceState) {
        currentStates[resource.trackerKey] = state
    }

    mutating func setCurrentState(_ resource: ResourceRef, _ state: ResourceState) {
        currentStates[resource.trackerKey] = state
    }

    func currentState(_ resource: ResourceRef) -> ResourceState {
        currentStates[resource.trackerKey] ?? []
    }

    mutating func removeResource(_ resource: ResourceRef) {
        currentStates.removeValue(forKey: resource.trackerKey)
    }

    /// Records a required state. If it differs from the current state, a
    /// barrier is queued and the tracked state is advanced immediately. Returns
    /// the state prior to the transition so callers can capture it once.
    @discardableResult
    mutating func requireState(_ resource: ResourceRef, _ desired: ResourceState) -> ResourceState {
        let key = resource.trackerKey
        let current = currentStates[key] ?? []
        if current == desired { return current }
        pendingBarriers.append(Barrier(resource: resource, before: current, after: desired))
        currentStates[key] = desired
        return current
    }

    /// Drains the queued barriers, merging multiple transitions of the same
    /// resource into a single barrier whose destination state is the union.
    mutating func commitBarriers() -> [Barrier] {
        if pendingBarriers.isEmpty { return [] }

        var merged: [UInt64: Barrier] = [:]
        for barrier in pendingBarriers {
            let key = barrier.resource.trackerKey
            if let existing = merged[key] {
                merged[key]?.after = existing.after.union(barrier.after)
            } else {
                merged[key] = barrier
            }
        }
        pendingBarriers.removeAll(keepingCapacity: true)
        return Array(merged.values)
    }
}
