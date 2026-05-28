import EngineKernel
import SIMDCompat

// MARK: - Trigger event types

public enum TriggerEventKind: String, Sendable, Equatable, CaseIterable {
    case enter
    case exit
}

public struct TriggerEvent: Sendable, Equatable {
    public var triggerEntity: EntityID
    public var otherEntity: EntityID
    public var kind: TriggerEventKind

    public init(triggerEntity: EntityID, otherEntity: EntityID, kind: TriggerEventKind) {
        self.triggerEntity = triggerEntity
        self.otherEntity = otherEntity
        self.kind = kind
    }
}

/// Per-frame trigger overlap state. Written by the schedule before scripts run.
/// Scripts read this via `ScriptContext.triggerEvents` to react to enter/exit pairs.
public struct TriggerFrameResource: Sendable, Equatable {
    /// Pairs that began overlapping this frame.
    public var enters: [TriggerEvent]
    /// Pairs that stopped overlapping this frame.
    public var exits: [TriggerEvent]
    /// All pairs currently overlapping this frame (enter + ongoing).
    public var active: [TriggerEvent]

    public var isEmpty: Bool { enters.isEmpty && exits.isEmpty }

    public init(enters: [TriggerEvent] = [],
                exits: [TriggerEvent] = [],
                active: [TriggerEvent] = []) {
        self.enters = enters
        self.exits = exits
        self.active = active
    }
}

// MARK: - Trigger detection

struct TriggerPair: Hashable, Sendable {
    var trigger: EntityID
    var other: EntityID
}

/// Runs trigger overlap detection against the spatial index and produces a
/// `TriggerFrameResource` for the current frame.
final class TriggerDetector: @unchecked Sendable {
    private var previousPairs: Set<TriggerPair> = []

    func detect(in index: SpatialIndexResource) -> TriggerFrameResource {
        let triggers = index.entries.filter { $0.isTrigger }
        guard !triggers.isEmpty else {
            let resource = TriggerFrameResource()
            previousPairs = []
            return resource
        }

        var currentPairs = Set<TriggerPair>()
        var active: [TriggerEvent] = []

        // Broadphase: for each trigger, test overlap against every non-trigger entry.
        for triggerEntry in triggers {
            let triggerBounds = triggerEntry.bounds
            for otherEntry in index.entries where otherEntry.entity != triggerEntry.entity {
                guard !otherEntry.isTrigger else { continue }
                guard triggerBounds.intersects(otherEntry.bounds) else { continue }
                guard layersOverlap(trigger: triggerEntry, other: otherEntry) else { continue }

                let pair = TriggerPair(trigger: triggerEntry.entity, other: otherEntry.entity)
                currentPairs.insert(pair)
                active.append(TriggerEvent(
                    triggerEntity: triggerEntry.entity,
                    otherEntity: otherEntry.entity,
                    kind: .enter
                ))
            }
        }

        let enteredPairs = currentPairs.subtracting(previousPairs)
        let exitedPairs  = previousPairs.subtracting(currentPairs)

        let enters = enteredPairs.map {
            TriggerEvent(triggerEntity: $0.trigger, otherEntity: $0.other, kind: .enter)
        }
        let exits = exitedPairs.map {
            TriggerEvent(triggerEntity: $0.trigger, otherEntity: $0.other, kind: .exit)
        }

        previousPairs = currentPairs
        return TriggerFrameResource(enters: enters, exits: exits, active: active)
    }

    func reset() {
        previousPairs.removeAll()
    }
}

private func layersOverlap(trigger: SpatialIndexEntry, other: SpatialIndexEntry) -> Bool {
    if trigger.layerMask == .max && other.layerMask == .max { return true }
    if other.layerID == 0 && trigger.layerMask & 1 != 0 { return true }
    return (trigger.layerMask & (1 << other.layerID)) != 0
}
