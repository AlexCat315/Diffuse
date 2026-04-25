import Foundation
import CoreGraphics
import EngineKernel
import PlatformShell

/// Routes window-local input events to nodes in the GuavaUI tree.
///
/// Per-window, per-tree. Construct one `EventDispatcher` for each `NodeTree`
/// and feed it events from `SDL3PlatformHost`'s polling loop.
///
/// Delivery model (DOM-style):
/// 1. `capture` phase — root → target, ancestors get a chance first
/// 2. `target` phase — the deepest hit-tested node
/// 3. `bubble`  phase — target → root, ancestors get a chance last
///
/// A handler returning `.handled` stops propagation in the current phase.
/// `PointerCapture.acquire` overrides hit-testing for non-down pointer events.
public final class EventDispatcher {

    public let tree: NodeTree
    public let interactions: InteractionRegistry
    public let capture: PointerCapture
    public let focusChain: FocusChain
    public let windowID: WindowID

    /// Phase 5b: optional input mirror. When set, hit-test consults the
    /// `InputScene` (cached classification + version-keyed focus chain) and
    /// the cursor walk reads `InputNode.cursor`. When `nil`, dispatch falls
    /// back to walking the live `Node` tree.
    public weak var inputScene: InputScene? {
        didSet { focusChain.inputScene = inputScene }
    }

    /// Invoked whenever the resolved hover cursor changes. The dispatcher
    /// computes the cursor by walking the hover path leaf → root and using
    /// the deepest non-nil `Node.cursor`. `nil` resolves to `.arrow`.
    /// Callers (typically the platform host) should forward this to
    /// `Shell.setCursor(_:)`.
    public var cursorSink: ((SystemCursor) -> Void)?
    /// Optional debug hook for tooling. It is invoked after each handler call
    /// with the resolved route metadata and result.
    public var traceSink: ((InputDispatchTrace) -> Void)?
    private var activeCursor: SystemCursor = .arrow

    /// Last known pointer position from `mouseMotion`. Used to hit-test wheel
    /// events (which carry no position on SDL3) so they reach the node under
    /// the cursor instead of only the root or focused node.
    private var lastCursor: CGPoint?
    /// Root → leaf path currently considered hovered. Derived from motion
    /// hit-testing and diffed against the next motion path to synthesize
    /// enter / leave transitions.
    private var hoveredPath: [Node] = []

    public init(tree: NodeTree,
                interactions: InteractionRegistry,
                capture: PointerCapture,
                focusChain: FocusChain,
                windowID: WindowID = .main) {
        self.tree = tree
        self.interactions = interactions
        self.capture = capture
        self.focusChain = focusChain
        self.windowID = windowID
    }

    // MARK: - Public dispatch

    public func dispatch(_ event: InputEvent) {
        switch event {
        case .mouseButtonDown(let e): dispatchPointerDown(e)
        case .mouseButtonUp(let e):   dispatchPointerUp(e)
        case .mouseMotion(let e):     dispatchMotion(e)
        case .mouseWheel(let e):      dispatchWheel(e)
        case .keyDown(let e):         dispatchKey(e, phase: .down)
        case .keyUp(let e):           dispatchKey(e, phase: .up)
        case .textEditing(let e):     dispatchTextEditing(e)
        case .textInput(let s):       dispatchText(s)
        default:
            // Window lifecycle events are not handled here.
            break
        }
    }

    // MARK: - Pointer

    private func dispatchPointerDown(_ event: MouseButtonEvent) {
        let point = CGPoint(x: CGFloat(event.x), y: CGFloat(event.y))
        lastCursor = point
        if deliverGlobalRoutes(kind: .pointer(event, .down),
                               role: .scrollChrome,
                               minPriority: .chrome) == .handled {
            return
        }
        guard let hit = hitTest(point: point) else { return }
        if deliverPriority(path: hit.path,
                           kind: .pointer(event, .down),
                           minPriority: .chrome,
                           phase: .capture) == .handled {
            return
        }
        _ = deliver(path: hit.path, kind: .pointer(event, .down))
        // Auto-focus on click for focusable targets.
        if hit.node.isFocusable {
            focusChain.focus(hit.node)
        }
    }

    private func dispatchPointerUp(_ event: MouseButtonEvent) {
        lastCursor = CGPoint(x: CGFloat(event.x), y: CGFloat(event.y))
        if let captured = capture.target {
            let path = pathFromRoot(to: captured)
            _ = deliver(path: path, kind: .pointer(event, .up))
            return
        }
        let point = CGPoint(x: CGFloat(event.x), y: CGFloat(event.y))
        guard let hit = hitTest(point: point) else { return }
        _ = deliver(path: hit.path, kind: .pointer(event, .up))
    }

    private func dispatchMotion(_ event: MouseMotionEvent) {
        lastCursor = CGPoint(x: CGFloat(event.x), y: CGFloat(event.y))
        if let captured = capture.target {
            let path = pathFromRoot(to: captured)
            updateHoverPath(to: path)
            _ = deliver(path: path, kind: .motion(event))
            return
        }
        let point = CGPoint(x: CGFloat(event.x), y: CGFloat(event.y))
        guard let hit = hitTest(point: point) else {
            updateHoverPath(to: [])
            return
        }
        updateHoverPath(to: hit.path)
        _ = deliver(path: hit.path, kind: .motion(event))
    }

    private func dispatchWheel(_ event: MouseWheelEvent) {
        var event = event
        if let mouseX = event.mouseX, let mouseY = event.mouseY {
            if mouseX == 0, mouseY == 0, let lastCursor {
                event.mouseX = Float(lastCursor.x)
                event.mouseY = Float(lastCursor.y)
            } else {
                lastCursor = CGPoint(x: CGFloat(mouseX), y: CGFloat(mouseY))
            }
        } else if let lastCursor {
            event.mouseX = Float(lastCursor.x)
            event.mouseY = Float(lastCursor.y)
        }
        let hitPath = lastCursor.flatMap { cursor in
            hitTest(point: cursor)?.path
        }
        let focusedPath = focusChain.focused.map(pathFromRoot)
        let preferredFocusedPath = preferredFocusedWheelPath(from: focusedPath)

        // Wheel delivery is target-first rather than full capture/target/bubble.
        // Nested scrollables need the deepest target to consume the gesture
        // before an ancestor ScrollView moves, otherwise inner editors can
        // never keep their own scroll context.
        if let preferredFocusedPath,
           deliverWheel(path: preferredFocusedPath, event: event) == .handled {
            return
        }
        if let hitPath,
           !sameWheelTarget(hitPath, preferredFocusedPath),
           deliverWheel(path: hitPath, event: event) == .handled {
            return
        }
        if let focusedPath,
           !sameWheelTarget(focusedPath, preferredFocusedPath),
           !sameWheelTarget(focusedPath, hitPath),
           deliverWheel(path: focusedPath, event: event) == .handled {
            return
        }
        if deliverGlobalRoutes(kind: .wheel(event),
                               role: .scroll,
                               minPriority: .normal) == .handled {
            return
        }
        guard let root = tree.root else { return }
        _ = deliverWheel(path: [root], event: event)
    }

    /// Hit-test entry point. Routes through the `InputScene` mirror when
    /// wired (Phase 5b), otherwise walks the live `Node` tree.
    private func hitTest(point: CGPoint) -> HitResult? {
        if let scene = inputScene {
            return HitTester.hitTest(scene: scene, point: point)
        }
        guard let root = tree.root else { return nil }
        return HitTester.hitTest(rootNode: root, point: point)
    }

    // MARK: - Key

    private func dispatchKey(_ event: KeyEvent, phase: KeyPhase) {
        let kind = EventKind.key(event, phase)
        // Pointer-capture intercept: while a node owns capture (typically a
        // drag in progress), give its key handler the first opportunity to
        // consume the event. Lets drags implement Esc-to-cancel without
        // also needing keyboard focus.
        if let captured = capture.target,
           invoke(node: captured, kind: kind, phase: .target) == .handled {
            return
        }
        let focusedPath = focusChain.focused.map(pathFromRoot)
        if let focusedPath,
           deliverKeyPath(focusedPath, event: event, phase: phase) == .handled {
            return
        }
        let excluded = Set((focusedPath ?? []).map(ObjectIdentifier.init))
        _ = deliverGlobalRoutes(kind: kind,
                                role: .shortcut,
                                minPriority: .system,
                                excluding: excluded)
    }

    private func dispatchText(_ text: String) {
        guard let focused = focusChain.focused else { return }
        let path = pathFromRoot(to: focused)
        _ = deliver(path: path, kind: .text(text))
    }

    private func dispatchTextEditing(_ event: TextEditingEvent) {
        guard let focused = focusChain.focused else { return }
        let path = pathFromRoot(to: focused)
        _ = deliver(path: path, kind: .editing(event))
    }

    // MARK: - Delivery

    private enum EventKind {
        case pointer(MouseButtonEvent, PointerPhase)
        case motion(MouseMotionEvent)
        case wheel(MouseWheelEvent)
        case key(KeyEvent, KeyPhase)
        case editing(TextEditingEvent)
        case text(String)
    }

    private struct RouteCandidate {
        var node: Node
        var route: InputHandlerRoute
        var depth: Int
    }

    private func deliver(path: [Node], kind: EventKind) -> EventResult {
        guard !path.isEmpty else { return .ignored }

        // Capture phase: root → target (exclusive of target).
        for node in path.dropLast() {
            if invoke(node: node, kind: kind, phase: .capture) == .handled { return .handled }
        }

        // Target phase.
        if let target = path.last,
           invoke(node: target, kind: kind, phase: .target) == .handled {
            return .handled
        }

        // Bubble phase: target's parent → root.
        for node in path.dropLast().reversed() {
            if invoke(node: node, kind: kind, phase: .bubble) == .handled { return .handled }
        }

        return .ignored
    }

    private func deliverWheel(path: [Node], event: MouseWheelEvent) -> EventResult {
        guard !path.isEmpty else { return .ignored }

        if let target = path.last,
           invoke(node: target, kind: .wheel(event), phase: .target) == .handled {
            return .handled
        }

        for node in path.dropLast().reversed() {
            if invoke(node: node, kind: .wheel(event), phase: .bubble) == .handled {
                return .handled
            }
        }

        return .ignored
    }

    private func deliverPriority(path: [Node],
                                 kind: EventKind,
                                 minPriority: InputRoutingPriority,
                                 phase: EventPhase) -> EventResult {
        for candidate in routeCandidates(in: path,
                                         kind: kind,
                                         minPriority: minPriority) {
            if invoke(node: candidate.node, kind: kind, phase: phase) == .handled {
                return .handled
            }
        }
        return .ignored
    }

    private func deliverGlobalRoutes(kind: EventKind,
                                     role: InputHandlerRole,
                                     minPriority: InputRoutingPriority,
                                     excluding excludedNodes: Set<ObjectIdentifier> = []) -> EventResult {
        guard let root = tree.root else { return .ignored }
        for candidate in routeCandidates(rootedAt: root,
                                         kind: kind,
                                         role: role,
                                         minPriority: minPriority)
            where !excludedNodes.contains(ObjectIdentifier(candidate.node)) {
            let phase: EventPhase = (role == .shortcut || role == .scrollChrome) ? .capture : .target
            if invoke(node: candidate.node, kind: kind, phase: phase) == .handled {
                return .handled
            }
        }
        return .ignored
    }

    private func routeCandidates(in path: [Node],
                                 kind: EventKind,
                                 minPriority: InputRoutingPriority = .background) -> [RouteCandidate] {
        path.enumerated().compactMap { index, node in
            let handlers = interactions.handlers(for: node)
            guard let route = route(in: handlers, kind: kind),
                  route.priority >= minPriority else {
                return nil
            }
            return RouteCandidate(node: node, route: route, depth: index)
        }
        .sorted(by: routeCandidateSort)
    }

    private func routeCandidates(rootedAt root: Node,
                                 kind: EventKind,
                                 role: InputHandlerRole,
                                 minPriority: InputRoutingPriority = .background) -> [RouteCandidate] {
        var out: [RouteCandidate] = []
        collectRouteCandidates(node: root,
                               depth: 0,
                               kind: kind,
                               role: role,
                               minPriority: minPriority,
                               into: &out)
        return out.sorted(by: routeCandidateSort)
    }

    private func collectRouteCandidates(node: Node,
                                        depth: Int,
                                        kind: EventKind,
                                        role: InputHandlerRole,
                                        minPriority: InputRoutingPriority,
                                        into out: inout [RouteCandidate]) {
        let handlers = interactions.handlers(for: node)
        if let route = route(in: handlers, kind: kind),
           route.role == role,
           route.priority >= minPriority {
            out.append(RouteCandidate(node: node, route: route, depth: depth))
        }
        for child in node.children {
            collectRouteCandidates(node: child,
                                   depth: depth + 1,
                                   kind: kind,
                                   role: role,
                                   minPriority: minPriority,
                                   into: &out)
        }
    }

    private func routeCandidateSort(_ lhs: RouteCandidate,
                                    _ rhs: RouteCandidate) -> Bool {
        if lhs.route.priority != rhs.route.priority {
            return lhs.route.priority > rhs.route.priority
        }
        return lhs.depth > rhs.depth
    }

    private func deliverKeyPath(_ path: [Node],
                                event: KeyEvent,
                                phase: KeyPhase) -> EventResult {
        let kind = EventKind.key(event, phase)
        for candidate in routeCandidates(in: path,
                                         kind: kind,
                                         minPriority: .system)
            where candidate.route.role == .shortcut {
            if invoke(node: candidate.node, kind: kind, phase: .capture) == .handled {
                return .handled
            }
        }
        return deliver(path: path, kind: kind)
    }

    private func preferredFocusedWheelPath(from focusedPath: [Node]?) -> [Node]? {
        guard let focusedPath,
              let focused = focusedPath.last,
              let priority = focused.attachments[WheelRoutingAttachmentKey.priority]
                as? WheelRoutingPriority,
              priority == .preferFocused else {
            return nil
        }
        return focusedPath
    }

    private func sameWheelTarget(_ lhs: [Node]?, _ rhs: [Node]?) -> Bool {
        guard let lhs = lhs?.last, let rhs = rhs?.last else { return false }
        return lhs === rhs
    }

    private func invoke(node: Node, kind: EventKind, phase: EventPhase) -> EventResult {
        let handlers = interactions.handlers(for: node)
        let result: EventResult = switch kind {
        case .pointer(let e, let pp): handlers.pointer?(e, pp, phase) ?? .ignored
        case .motion(let e):  handlers.motion?(e, phase)  ?? .ignored
        case .wheel(let e):   handlers.wheel?(e, phase)   ?? .ignored
        case .key(let e, let keyPhase):
            keyHandler(in: handlers, phase: keyPhase)?(e, phase) ?? .ignored
        case .editing(let e): handlers.editing?(e, phase) ?? .ignored
        case .text(let s):    handlers.text?(s, phase)    ?? .ignored
        }
        traceSink?(InputDispatchTrace(kind: dispatchKind(for: kind),
                                      nodeID: node.id,
                                      phase: phase,
                                      route: route(in: handlers, kind: kind),
                                      result: result))
        return result
    }

    // MARK: - Helpers

    /// Build root → leaf path for a given node by walking the parent chain.
    private func pathFromRoot(to node: Node) -> [Node] {
        var out: [Node] = []
        var cur: Node? = node
        while let n = cur {
            out.append(n)
            cur = n.parent
        }
        return out.reversed()
    }

    private func keyHandler(in handlers: InteractionRegistry.Handlers,
                            phase: KeyPhase) -> ((KeyEvent, EventPhase) -> EventResult)? {
        switch phase {
        case .down: return handlers.key
        case .up: return handlers.keyUp
        }
    }

    private func route(in handlers: InteractionRegistry.Handlers,
                       kind: EventKind) -> InputHandlerRoute? {
        switch kind {
        case .pointer: return handlers.pointerRoute
        case .motion: return handlers.motionRoute
        case .wheel: return handlers.wheelRoute
        case .key(_, let phase):
            switch phase {
            case .down: return handlers.keyRoute
            case .up: return handlers.keyUpRoute
            }
        case .editing: return handlers.editingRoute
        case .text: return handlers.textRoute
        }
    }

    private func dispatchKind(for kind: EventKind) -> InputDispatchKind {
        switch kind {
        case .pointer(_, let phase):
            switch phase {
            case .down: return .pointerDown
            case .up: return .pointerUp
            }
        case .motion: return .motion
        case .wheel: return .wheel
        case .key(_, let phase):
            switch phase {
            case .down: return .keyDown
            case .up: return .keyUp
            }
        case .editing: return .editing
        case .text: return .text
        }
    }

    private func updateHoverPath(to newPath: [Node]) {
        let oldPath = hoveredPath
        let common = commonPrefixLength(oldPath, newPath)

        if common == oldPath.count && common == newPath.count {
            return
        }

        if common < oldPath.count {
            for node in oldPath[common...].reversed() {
                interactions.handlers(for: node).hover?(.leave)
            }
        }
        if common < newPath.count {
            for node in newPath[common...] {
                interactions.handlers(for: node).hover?(.enter)
            }
        }

        hoveredPath = newPath
        updateCursor(for: newPath)
    }

    private func updateCursor(for path: [Node]) {
        var resolved: SystemCursor = .arrow
        // Prefer the cached InputNode.cursor when the mirror is wired so
        // dispatch never reads back into the live Node graph for cursor
        // resolution.
        for node in path.reversed() {
            let c = node.inputNode?.cursor ?? node.cursor
            if let c {
                resolved = c
                break
            }
        }
        if resolved != activeCursor {
            activeCursor = resolved
            cursorSink?(resolved)
        }
    }

    private func commonPrefixLength(_ lhs: [Node], _ rhs: [Node]) -> Int {
        let count = min(lhs.count, rhs.count)
        for index in 0..<count where lhs[index] !== rhs[index] {
            return index
        }
        return count
    }
}
