import Foundation
import CoreGraphics
import EngineKernel

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

    /// Last known pointer position from `mouseMotion`. Used to hit-test wheel
    /// events (which carry no position on SDL3) so they reach the node under
    /// the cursor instead of only the root or focused node.
    private var lastCursor: CGPoint?

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
        case .keyDown(let e),
             .keyUp(let e):           dispatchKey(e)
        case .textInput(let s):       dispatchText(s)
        default:
            // Window lifecycle events are not handled here.
            break
        }
    }

    // MARK: - Pointer

    private func dispatchPointerDown(_ event: MouseButtonEvent) {
        guard let root = tree.root else { return }
        let point = CGPoint(x: CGFloat(event.x), y: CGFloat(event.y))
        guard let hit = HitTester.hitTest(rootNode: root, point: point) else { return }
        deliver(path: hit.path, kind: .pointer(event, .down))
        // Auto-focus on click for focusable targets.
        if hit.node.isFocusable {
            focusChain.focus(hit.node)
        }
    }

    private func dispatchPointerUp(_ event: MouseButtonEvent) {
        if let captured = capture.target {
            let path = pathFromRoot(to: captured)
            deliver(path: path, kind: .pointer(event, .up))
            return
        }
        guard let root = tree.root else { return }
        let point = CGPoint(x: CGFloat(event.x), y: CGFloat(event.y))
        guard let hit = HitTester.hitTest(rootNode: root, point: point) else { return }
        deliver(path: hit.path, kind: .pointer(event, .up))
    }

    private func dispatchMotion(_ event: MouseMotionEvent) {
        lastCursor = CGPoint(x: CGFloat(event.x), y: CGFloat(event.y))
        if let captured = capture.target {
            let path = pathFromRoot(to: captured)
            deliver(path: path, kind: .motion(event))
            return
        }
        guard let root = tree.root else { return }
        let point = CGPoint(x: CGFloat(event.x), y: CGFloat(event.y))
        guard let hit = HitTester.hitTest(rootNode: root, point: point) else { return }
        deliver(path: hit.path, kind: .motion(event))
    }

    private func dispatchWheel(_ event: MouseWheelEvent) {
        // Prefer hit-testing under the last known cursor so the scrollable
        // region under the pointer wins. Fall back to the focused node, then
        // the root node.
        if let cursor = lastCursor,
           let root = tree.root,
           let hit = HitTester.hitTest(rootNode: root, point: cursor) {
            deliver(path: hit.path, kind: .wheel(event))
            return
        }
        if let focused = focusChain.focused {
            let path = pathFromRoot(to: focused)
            deliver(path: path, kind: .wheel(event))
            return
        }
        guard let root = tree.root else { return }
        deliver(path: [root], kind: .wheel(event))
    }

    // MARK: - Key

    private func dispatchKey(_ event: KeyEvent) {
        guard let focused = focusChain.focused else { return }
        let path = pathFromRoot(to: focused)
        deliver(path: path, kind: .key(event))
    }

    private func dispatchText(_ text: String) {
        guard let focused = focusChain.focused else { return }
        let path = pathFromRoot(to: focused)
        deliver(path: path, kind: .text(text))
    }

    // MARK: - Delivery

    private enum EventKind {
        case pointer(MouseButtonEvent, PointerPhase)
        case motion(MouseMotionEvent)
        case wheel(MouseWheelEvent)
        case key(KeyEvent)
        case text(String)
    }

    private func deliver(path: [Node], kind: EventKind) {
        guard !path.isEmpty else { return }

        // Capture phase: root → target (exclusive of target).
        for node in path.dropLast() {
            if invoke(node: node, kind: kind, phase: .capture) == .handled { return }
        }

        // Target phase.
        if let target = path.last,
           invoke(node: target, kind: kind, phase: .target) == .handled {
            return
        }

        // Bubble phase: target's parent → root.
        for node in path.dropLast().reversed() {
            if invoke(node: node, kind: kind, phase: .bubble) == .handled { return }
        }
    }

    private func invoke(node: Node, kind: EventKind, phase: EventPhase) -> EventResult {
        let handlers = interactions.handlers(for: node)
        switch kind {
        case .pointer(let e, let pp): return handlers.pointer?(e, pp, phase) ?? .ignored
        case .motion(let e):  return handlers.motion?(e, phase)  ?? .ignored
        case .wheel(let e):   return handlers.wheel?(e, phase)   ?? .ignored
        case .key(let e):     return handlers.key?(e, phase)     ?? .ignored
        case .text(let s):    return handlers.text?(s, phase)    ?? .ignored
        }
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
}
