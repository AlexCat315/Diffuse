import EngineKernel
import SIMDCompat

// MARK: - Trigger event types

public enum TriggerEventKind: String, Sendable, Equatable, CaseIterable {
    case enter
    case exit
    case active
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
