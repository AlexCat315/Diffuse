import Foundation
import EngineKernel

/// Phase of event delivery in the capture/target/bubble model.
public enum EventPhase: Sendable {
    case capture
    case target
    case bubble
}

/// Result of a handler — `handled` stops bubble (and capture if returned in capture phase).
public enum EventResult: Sendable {
    case handled
    case ignored
}

/// Per-node handler closures registered by Compose-layer modifiers.
///
/// `Node` itself stays free of handler state so Runtime types remain
/// serialisation-friendly. Handlers live in this side table keyed by node identity.
public final class InteractionRegistry {

    public struct Handlers {
        public var pointer: ((MouseButtonEvent, EventPhase) -> EventResult)?
        public var motion:  ((MouseMotionEvent, EventPhase) -> EventResult)?
        public var wheel:   ((MouseWheelEvent,  EventPhase) -> EventResult)?
        public var key:     ((KeyEvent,         EventPhase) -> EventResult)?

        public init() {}

        public var isEmpty: Bool {
            pointer == nil && motion == nil && wheel == nil && key == nil
        }
    }

    private var table: [ObjectIdentifier: Handlers] = [:]

    public init() {}

    // MARK: - Registration

    public func handlers(for node: Node) -> Handlers {
        table[ObjectIdentifier(node)] ?? Handlers()
    }

    public func setPointer(_ node: Node,
                           _ handler: @escaping (MouseButtonEvent, EventPhase) -> EventResult) {
        var h = handlers(for: node); h.pointer = handler
        table[ObjectIdentifier(node)] = h
    }

    public func setMotion(_ node: Node,
                          _ handler: @escaping (MouseMotionEvent, EventPhase) -> EventResult) {
        var h = handlers(for: node); h.motion = handler
        table[ObjectIdentifier(node)] = h
    }

    public func setWheel(_ node: Node,
                         _ handler: @escaping (MouseWheelEvent, EventPhase) -> EventResult) {
        var h = handlers(for: node); h.wheel = handler
        table[ObjectIdentifier(node)] = h
    }

    public func setKey(_ node: Node,
                       _ handler: @escaping (KeyEvent, EventPhase) -> EventResult) {
        var h = handlers(for: node); h.key = handler
        table[ObjectIdentifier(node)] = h
    }

    public func remove(_ node: Node) {
        table.removeValue(forKey: ObjectIdentifier(node))
    }

    public var count: Int { table.count }
}
