import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

/// One mounted graph with its own interaction, focus, capture, portal and
/// text holders, plus real pointer and keyboard dispatch.
final class InteractiveScene {
    let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
    let registry = InteractionRegistry()
    let focus = FocusChain()
    let capture = PointerCapture()
    let portal = PortalStore()
    var width: Float = 800
    var height: Float = 600

    static func run(width: Float = 800, height: Float = 600, _ body: (InteractiveScene) throws -> Void) rethrows {
        try GlobalTestLock.locked {
            let oldRegistry = InteractionRegistryHolder.current, oldFocus = FocusChainHolder.current
            let oldCapture = PointerCaptureHolder.current, oldPortal = PortalStoreHolder.current
            let oldText = TextEnvironmentHolder.current
            let scene = InteractiveScene()
            scene.width = width; scene.height = height
            InteractionRegistryHolder.current = scene.registry
            FocusChainHolder.current = scene.focus
            PointerCaptureHolder.current = scene.capture
            PortalStoreHolder.current = scene.portal
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer {
                scene.graph.install(root: EmptyView())
                AnimatorScheduler.current.tick(deltaTime: 1)
                InteractionRegistryHolder.current = oldRegistry; FocusChainHolder.current = oldFocus
                PointerCaptureHolder.current = oldCapture; PortalStoreHolder.current = oldPortal
                TextEnvironmentHolder.current = oldText
            }
            try body(scene)
        }
    }

    func install<V: View>(_ view: V) { graph.install(root: view); settle() }

    func settle(ticks: Int = 5, delta: Double = 1) {
        for _ in 0..<ticks {
            graph.recomposer.commitAll()
            graph.computeLayout(width: width, height: height)
            AnimatorScheduler.current.tick(deltaTime: delta)
        }
        graph.recomposer.commitAll()
        graph.computeLayout(width: width, height: height)
    }

    var dispatcher: EventDispatcher {
        EventDispatcher(tree: graph.tree, interactions: registry, capture: capture, focusChain: focus)
    }

    var nodes: [Node] { Self.descendants(graph.tree.root) }
    static func descendants(_ node: Node?) -> [Node] {
        guard let node else { return [] }
        return [node] + node.children.flatMap { descendants($0) }
    }

    func first(_ predicate: (Node) -> Bool) -> Node? { nodes.first(where: predicate) }
    func all(_ predicate: (Node) -> Bool) -> [Node] { nodes.filter(predicate) }
    func labelled(_ label: String, role: AccessibilityRole? = nil) -> Node? {
        first { $0.accessibility?.label == label && (role == nil || $0.accessibility?.role == role) }
    }
    func named(_ name: String) -> Node? {
        first { $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == name }
    }

    func click(_ node: Node, clicks: Int = 1, modifiers: KeyModifiers = []) {
        click(at: CGPoint(x: node.absoluteFrame.midX, y: node.absoluteFrame.midY), clicks: clicks, modifiers: modifiers)
    }

    func click(at point: CGPoint, clicks: Int = 1, modifiers: KeyModifiers = []) {
        let event = MouseButtonEvent(button: .left, x: Float(point.x), y: Float(point.y), clicks: UInt8(clicks), modifiers: modifiers)
        let dispatcher = dispatcher
        dispatcher.dispatch(.mouseButtonDown(event)); graph.recomposer.commitAll()
        dispatcher.dispatch(.mouseButtonUp(event)); settle()
    }

    func drag(from start: CGPoint, to end: CGPoint, steps: Int = 6) {
        let dispatcher = dispatcher
        dispatcher.dispatch(.mouseButtonDown(MouseButtonEvent(button: .left, x: Float(start.x), y: Float(start.y), clicks: 1)))
        graph.recomposer.commitAll()
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let x = start.x + (end.x - start.x) * t, y = start.y + (end.y - start.y) * t
            dispatcher.dispatch(.mouseMotion(MouseMotionEvent(x: Float(x), y: Float(y), deltaX: 0, deltaY: 0)))
            graph.recomposer.commitAll(); graph.computeLayout(width: width, height: height)
        }
        dispatcher.dispatch(.mouseButtonUp(MouseButtonEvent(button: .left, x: Float(end.x), y: Float(end.y), clicks: 1)))
        settle()
    }

    func key(_ code: UInt32, modifiers: KeyModifiers = []) {
        dispatcher.dispatch(.keyDown(KeyEvent(scancode: code, keycode: 0, modifiers: modifiers, isRepeat: false)))
        settle()
    }
}
