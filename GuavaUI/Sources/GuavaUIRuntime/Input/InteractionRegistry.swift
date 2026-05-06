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

/// Distinguishes key-down from key-up within keyboard delivery.
public enum KeyPhase: Sendable {
    case down
    case up
}

/// Boundary transition derived from mouse-motion hit-test changes.
public enum HoverPhase: Sendable {
    case enter
    case leave
}

/// Semantic role attached to an input handler. Dispatch still works without
/// roles, but richer roles let the router resolve chrome/focus/viewport
/// conflicts without hard-coding component types.
public enum InputHandlerRole: Sendable, Equatable {
    case control
    case scroll
    case scrollChrome
    case textInput
    case viewport
    case workspace
    case drag
    case shortcut
    case custom(String)
}

/// Coarse priority band used by the dispatcher before falling back to normal
/// tree order. Values are intentionally spaced so future app layers can insert
/// intermediate priorities without changing the enum cases.
public struct InputRoutingPriority: Sendable, Comparable, Equatable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let background = InputRoutingPriority(rawValue: 0)
    public static let normal = InputRoutingPriority(rawValue: 100)
    public static let focused = InputRoutingPriority(rawValue: 200)
    public static let chrome = InputRoutingPriority(rawValue: 300)
    public static let capture = InputRoutingPriority(rawValue: 400)
    public static let modal = InputRoutingPriority(rawValue: 500)
    public static let system = InputRoutingPriority(rawValue: 600)

    public static func < (lhs: InputRoutingPriority, rhs: InputRoutingPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Metadata for a node handler in the input routing table.
public struct InputHandlerRoute: Sendable, Equatable {
    public var role: InputHandlerRole
    public var priority: InputRoutingPriority
    public var debugName: String

    public init(role: InputHandlerRole = .control,
                priority: InputRoutingPriority = .normal,
                debugName: String = "") {
        self.role = role
        self.priority = priority
        self.debugName = debugName
    }

    public static let control = InputHandlerRoute(role: .control,
                                                  priority: .normal,
                                                  debugName: "control")
    public static let scroll = InputHandlerRoute(role: .scroll,
                                                 priority: .normal,
                                                 debugName: "scroll")
    public static let scrollChrome = InputHandlerRoute(role: .scrollChrome,
                                                       priority: .chrome,
                                                       debugName: "scroll.chrome")
    public static let textInput = InputHandlerRoute(role: .textInput,
                                                    priority: .focused,
                                                    debugName: "text.input")
    public static let viewport = InputHandlerRoute(role: .viewport,
                                                   priority: .focused,
                                                   debugName: "viewport")
    public static let workspaceDrag = InputHandlerRoute(role: .workspace,
                                                        priority: .capture,
                                                        debugName: "workspace.drag")
    public static let shortcut = InputHandlerRoute(role: .shortcut,
                                                   priority: .system,
                                                   debugName: "shortcut")
}

public enum InputDispatchKind: Sendable, Equatable {
    case pointerDown
    case pointerUp
    case motion
    case wheel
    case keyDown
    case keyUp
    case editing
    case text
}

public struct InputDispatchTrace: Sendable, Equatable {
    public var kind: InputDispatchKind
    public var nodeID: ElementID
    public var phase: EventPhase
    public var route: InputHandlerRoute?
    public var result: EventResult

    public init(kind: InputDispatchKind,
                nodeID: ElementID,
                phase: EventPhase,
                route: InputHandlerRoute?,
                result: EventResult) {
        self.kind = kind
        self.nodeID = nodeID
        self.phase = phase
        self.route = route
        self.result = result
    }
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
        public var keyUp:   ((KeyEvent,         EventPhase) -> EventResult)?
        public var editing: ((TextEditingEvent, EventPhase) -> EventResult)?
        public var text:    ((String,           EventPhase) -> EventResult)?

        public var pointerRoute: InputHandlerRoute?
        public var motionRoute: InputHandlerRoute?
        public var wheelRoute: InputHandlerRoute?
        public var keyRoute: InputHandlerRoute?
        public var keyUpRoute: InputHandlerRoute?
        public var editingRoute: InputHandlerRoute?
        public var textRoute: InputHandlerRoute?

        public init() {}

        public var isEmpty: Bool {
            pointer == nil && hover == nil && motion == nil && wheel == nil
                && key == nil && keyUp == nil && editing == nil && text == nil
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
                           route: InputHandlerRoute = .control,
                           _ handler: @escaping (MouseButtonEvent, PointerPhase, EventPhase) -> EventResult) {
        withLock {
            var h = table[ObjectIdentifier(node)] ?? Handlers()
            h.pointer = handler
            h.pointerRoute = route
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
                          route: InputHandlerRoute = .control,
                          _ handler: @escaping (MouseMotionEvent, EventPhase) -> EventResult) {
        withLock {
            var h = table[ObjectIdentifier(node)] ?? Handlers()
            h.motion = handler
            h.motionRoute = route
            table[ObjectIdentifier(node)] = h
        }
    }

    public func setWheel(_ node: Node,
                         route: InputHandlerRoute = .scroll,
                         _ handler: @escaping (MouseWheelEvent, EventPhase) -> EventResult) {
        withLock {
            var h = table[ObjectIdentifier(node)] ?? Handlers()
            h.wheel = handler
            h.wheelRoute = route
            table[ObjectIdentifier(node)] = h
        }
    }

    public func setKey(_ node: Node,
                       route: InputHandlerRoute = .control,
                       _ handler: @escaping (KeyEvent, EventPhase) -> EventResult) {
        withLock {
            var h = table[ObjectIdentifier(node)] ?? Handlers()
            h.key = handler
            h.keyRoute = route
            table[ObjectIdentifier(node)] = h
        }
    }

    public func setKeyUp(_ node: Node,
                         route: InputHandlerRoute = .control,
                         _ handler: @escaping (KeyEvent, EventPhase) -> EventResult) {
        withLock {
            var h = table[ObjectIdentifier(node)] ?? Handlers()
            h.keyUp = handler
            h.keyUpRoute = route
            table[ObjectIdentifier(node)] = h
        }
    }

    public func setEditing(_ node: Node,
                           route: InputHandlerRoute = .textInput,
                           _ handler: @escaping (TextEditingEvent, EventPhase) -> EventResult) {
        withLock {
            var h = table[ObjectIdentifier(node)] ?? Handlers()
            h.editing = handler
            h.editingRoute = route
            table[ObjectIdentifier(node)] = h
        }
    }

    public func setText(_ node: Node,
                        route: InputHandlerRoute = .textInput,
                        _ handler: @escaping (String, EventPhase) -> EventResult) {
        withLock {
            var h = table[ObjectIdentifier(node)] ?? Handlers()
            h.text = handler
            h.textRoute = route
            table[ObjectIdentifier(node)] = h
        }
    }

    public func remove(_ node: Node) {
        withLock { _ = table.removeValue(forKey: ObjectIdentifier(node)) }
    }

    public var count: Int { withLock { table.count } }
}
