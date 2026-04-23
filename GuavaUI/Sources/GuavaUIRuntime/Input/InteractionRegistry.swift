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

/// Distinguishes button-down from button-up within the unified pointer handler.
public enum PointerPhase: Sendable {
    case down
    case up
}

/// Boundary transition derived from mouse-motion hit-test changes.
public enum HoverPhase: Sendable {
    case enter
    case leave
}

/// Per-node handler closures registered by Compose-layer modifiers.
///
/// `Node` itself stays free of handler state so Runtime types remain
/// serialisation-friendly. Handlers live in this side table keyed by node identity.
public final class InteractionRegistry {

    public struct Handlers {
        public var pointer: ((MouseButtonEvent, PointerPhase, EventPhase) -> EventResult)?
        public var hover:   ((HoverPhase) -> Void)?
        public var motion:  ((MouseMotionEvent, EventPhase) -> EventResult)?
        public var wheel:   ((MouseWheelEvent,  EventPhase) -> EventResult)?
        public var key:     ((KeyEvent,         EventPhase) -> EventResult)?
        public var editing: ((TextEditingEvent, EventPhase) -> EventResult)?
        public var text:    ((String,           EventPhase) -> EventResult)?

        public init() {}

        public var isEmpty: Bool {
            pointer == nil && hover == nil && motion == nil && wheel == nil && key == nil && editing == nil && text == nil
        }
    }

    private var table: [ObjectIdentifier: Handlers] = [:]
    private let lock = NSLock()

    public init() {}

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    // MARK: - Registration

    public func handlers(for node: Node) -> Handlers {
        withLock { table[ObjectIdentifier(node)] ?? Handlers() }
    }

    public func setPointer(_ node: Node,
                           _ handler: @escaping (MouseButtonEvent, PointerPhase, EventPhase) -> EventResult) {
        withLock {
            var h = table[ObjectIdentifier(node)] ?? Handlers(); h.pointer = handler
            table[ObjectIdentifier(node)] = h
        }
    }

    public func setHover(_ node: Node,
                         _ handler: @escaping (HoverPhase) -> Void) {
        withLock {
            var h = table[ObjectIdentifier(node)] ?? Handlers(); h.hover = handler
            table[ObjectIdentifier(node)] = h
        }
    }

    public func setMotion(_ node: Node,
                          _ handler: @escaping (MouseMotionEvent, EventPhase) -> EventResult) {
        withLock {
            var h = table[ObjectIdentifier(node)] ?? Handlers(); h.motion = handler
            table[ObjectIdentifier(node)] = h
        }
    }

    public func setWheel(_ node: Node,
                         _ handler: @escaping (MouseWheelEvent, EventPhase) -> EventResult) {
        withLock {
            var h = table[ObjectIdentifier(node)] ?? Handlers(); h.wheel = handler
            table[ObjectIdentifier(node)] = h
        }
    }

    public func setKey(_ node: Node,
                       _ handler: @escaping (KeyEvent, EventPhase) -> EventResult) {
        withLock {
            var h = table[ObjectIdentifier(node)] ?? Handlers(); h.key = handler
            table[ObjectIdentifier(node)] = h
        }
    }

    public func setEditing(_ node: Node,
                           _ handler: @escaping (TextEditingEvent, EventPhase) -> EventResult) {
        withLock {
            var h = table[ObjectIdentifier(node)] ?? Handlers(); h.editing = handler
            table[ObjectIdentifier(node)] = h
        }
    }

    public func setText(_ node: Node,
                        _ handler: @escaping (String, EventPhase) -> EventResult) {
        withLock {
            var h = table[ObjectIdentifier(node)] ?? Handlers(); h.text = handler
            table[ObjectIdentifier(node)] = h
        }
    }

    public func remove(_ node: Node) {
        withLock { _ = table.removeValue(forKey: ObjectIdentifier(node)) }
    }

    public var count: Int { withLock { table.count } }
}
