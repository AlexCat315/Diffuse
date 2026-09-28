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
public enum InputHandlerRole: Sendable, Equatable, Hashable {
    case control
    case scroll
    case scrollChrome
    case textInput
    case viewport
    case workspace
    case drag
    /// Transient UI presented above normal content (popover/menu/dialog chrome).
    /// Its keyboard handler gets first refusal while the overlay is mounted.
    case overlay
    case shortcut
    case custom(String)
}

/// Coarse priority band used by the dispatcher before falling back to normal
/// tree order. Values are intentionally spaced so future app layers can insert
/// intermediate priorities without changing the enum cases.
public struct InputRoutingPriority: Sendable, Comparable, Equatable, Hashable {
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
    public static let overlay = InputHandlerRoute(role: .overlay,
                                                  priority: .modal,
                                                  debugName: "overlay")
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

internal enum InputHandlerSlot: Hashable {
    case pointer
    case motion
    case wheel
    case key
    case keyUp
    case editing
    case text
}

internal struct RoutedInputNode {
    var node: Node
    var route: InputHandlerRoute
}

private struct RouteIndexKey: Hashable {
    var slot: InputHandlerSlot
    var role: InputHandlerRole
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
    private var nodes: [ObjectIdentifier: WeakNode] = [:]
    private var routedIndex: [RouteIndexKey: Set<ObjectIdentifier>] = [:]
    private let lock = NSLock()

    public init() {}

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    /// Bind this node's handler entry to its lifetime (规则 2): the first time a
    /// node registers a handler, attach a resource that removes the entry when
    /// the node leaves the tree. Cleanup is then owned by the node lifecycle —
    /// no `ViewGraph` teardown side-effect required.
    private func bindCleanup(to node: Node) {
        if node.firstResource(InteractionCleanupResource.self) == nil {
            node.addResource(InteractionCleanupResource(registry: self))
        }
    }

    // MARK: - Registration

    private final class WeakNode {
        weak var node: Node?

        init(_ node: Node) {
            self.node = node
        }
    }

    public func handlers(for node: Node) -> Handlers {
        withLock { table[ObjectIdentifier(node)] ?? Handlers() }
    }

    internal func routedNodes(slot: InputHandlerSlot,
                              role: InputHandlerRole,
                              minPriority: InputRoutingPriority) -> [RoutedInputNode] {
        withLock {
            guard let ids = routedIndex[RouteIndexKey(slot: slot, role: role)] else {
                return []
            }
            var out: [RoutedInputNode] = []
            out.reserveCapacity(ids.count)
            for id in ids {
                guard let handlers = table[id],
                      let node = nodes[id]?.node else {
                    continue
                }
                guard let route = self.route(in: handlers, slot: slot),
                      route.role == role,
                      route.priority >= minPriority else {
                    continue
                }
                out.append(RoutedInputNode(node: node, route: route))
            }
            return out
        }
    }

    public func setPointer(_ node: Node,
                           route: InputHandlerRoute = .control,
                           _ handler: @escaping (MouseButtonEvent, PointerPhase, EventPhase) -> EventResult) {
        let id = ObjectIdentifier(node)
        withLock {
            var h = table[id] ?? Handlers()
            let oldRoute = h.pointerRoute
            h.pointer = handler
            h.pointerRoute = route
            table[id] = h
            nodes[id] = WeakNode(node)
            updateRouteIndex(id: id, slot: .pointer, oldRoute: oldRoute, newRoute: route)
        }
        bindCleanup(to: node)
    }

    public func setHover(_ node: Node,
                         _ handler: @escaping (HoverPhase) -> Void) {
        let id = ObjectIdentifier(node)
        withLock {
            var h = table[id] ?? Handlers(); h.hover = handler
            table[id] = h
            nodes[id] = WeakNode(node)
        }
        bindCleanup(to: node)
    }

    public func setMotion(_ node: Node,
                          route: InputHandlerRoute = .control,
                          _ handler: @escaping (MouseMotionEvent, EventPhase) -> EventResult) {
        let id = ObjectIdentifier(node)
        withLock {
            var h = table[id] ?? Handlers()
            let oldRoute = h.motionRoute
            h.motion = handler
            h.motionRoute = route
            table[id] = h
            nodes[id] = WeakNode(node)
            updateRouteIndex(id: id, slot: .motion, oldRoute: oldRoute, newRoute: route)
        }
        bindCleanup(to: node)
    }

    public func setWheel(_ node: Node,
                         route: InputHandlerRoute = .scroll,
                         _ handler: @escaping (MouseWheelEvent, EventPhase) -> EventResult) {
        let id = ObjectIdentifier(node)
        withLock {
            var h = table[id] ?? Handlers()
            let oldRoute = h.wheelRoute
            h.wheel = handler
            h.wheelRoute = route
            table[id] = h
            nodes[id] = WeakNode(node)
            updateRouteIndex(id: id, slot: .wheel, oldRoute: oldRoute, newRoute: route)
        }
        bindCleanup(to: node)
    }

    public func setKey(_ node: Node,
                       route: InputHandlerRoute = .control,
                       _ handler: @escaping (KeyEvent, EventPhase) -> EventResult) {
        let id = ObjectIdentifier(node)
        withLock {
            var h = table[id] ?? Handlers()
            let oldRoute = h.keyRoute
            h.key = handler
            h.keyRoute = route
            table[id] = h
            nodes[id] = WeakNode(node)
            updateRouteIndex(id: id, slot: .key, oldRoute: oldRoute, newRoute: route)
        }
        bindCleanup(to: node)
    }

    public func setKeyUp(_ node: Node,
                         route: InputHandlerRoute = .control,
                         _ handler: @escaping (KeyEvent, EventPhase) -> EventResult) {
        let id = ObjectIdentifier(node)
        withLock {
            var h = table[id] ?? Handlers()
            let oldRoute = h.keyUpRoute
            h.keyUp = handler
            h.keyUpRoute = route
            table[id] = h
            nodes[id] = WeakNode(node)
            updateRouteIndex(id: id, slot: .keyUp, oldRoute: oldRoute, newRoute: route)
        }
        bindCleanup(to: node)
    }

    public func setEditing(_ node: Node,
                           route: InputHandlerRoute = .textInput,
                           _ handler: @escaping (TextEditingEvent, EventPhase) -> EventResult) {
        let id = ObjectIdentifier(node)
        withLock {
            var h = table[id] ?? Handlers()
            let oldRoute = h.editingRoute
            h.editing = handler
            h.editingRoute = route
            table[id] = h
            nodes[id] = WeakNode(node)
            updateRouteIndex(id: id, slot: .editing, oldRoute: oldRoute, newRoute: route)
        }
        bindCleanup(to: node)
    }

    public func setText(_ node: Node,
                        route: InputHandlerRoute = .textInput,
                        _ handler: @escaping (String, EventPhase) -> EventResult) {
        let id = ObjectIdentifier(node)
        withLock {
            var h = table[id] ?? Handlers()
            let oldRoute = h.textRoute
            h.text = handler
            h.textRoute = route
            table[id] = h
            nodes[id] = WeakNode(node)
            updateRouteIndex(id: id, slot: .text, oldRoute: oldRoute, newRoute: route)
        }
        bindCleanup(to: node)
    }

    public func remove(_ node: Node) {
        withLock {
            let id = ObjectIdentifier(node)
            _ = table.removeValue(forKey: id)
            _ = nodes.removeValue(forKey: id)
            removeRouteIndexes(for: id)
        }
    }

    public var count: Int { withLock { table.count } }

    private func updateRouteIndex(id: ObjectIdentifier,
                                  slot: InputHandlerSlot,
                                  oldRoute: InputHandlerRoute?,
                                  newRoute: InputHandlerRoute?) {
        if let oldRoute {
            let key = RouteIndexKey(slot: slot, role: oldRoute.role)
            routedIndex[key]?.remove(id)
            if routedIndex[key]?.isEmpty == true {
                routedIndex.removeValue(forKey: key)
            }
        }
        if let newRoute {
            routedIndex[RouteIndexKey(slot: slot, role: newRoute.role), default: []].insert(id)
        }
    }

    private func removeRouteIndexes(for id: ObjectIdentifier) {
        for key in Array(routedIndex.keys) {
            routedIndex[key]?.remove(id)
            if routedIndex[key]?.isEmpty == true {
                routedIndex.removeValue(forKey: key)
            }
        }
    }

    private func route(in handlers: Handlers, slot: InputHandlerSlot) -> InputHandlerRoute? {
        switch slot {
        case .pointer: return handlers.pointerRoute
        case .motion: return handlers.motionRoute
        case .wheel: return handlers.wheelRoute
        case .key: return handlers.keyRoute
        case .keyUp: return handlers.keyUpRoute
        case .editing: return handlers.editingRoute
        case .text: return handlers.textRoute
        }
    }
}

/// Node-owned cleanup for interaction handlers (坏味 #4 / 规则 2). Attached to a
/// node the first time it registers a handler; `unmount` (driven by
/// `Node.removeChild`) removes the node's entry from the registry. The registry
/// is held weakly so the resource never keeps a torn-down window alive.
final class InteractionCleanupResource: NodeResource {
    private weak var registry: InteractionRegistry?
    init(registry: InteractionRegistry) { self.registry = registry }
    func mount(node: Node) {}
    func unmount(node: Node) { registry?.remove(node) }
}
