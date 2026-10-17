import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("ScrollView input", .serialized)
struct ScrollViewInputTests: GuavaUIComposeSerializedSuite {
    private func nodes(_ node: Node?) -> [Node] {
        guard let node else { return [] }
        return [node] + node.children.flatMap { nodes($0) }
    }

    private func install(_ graph: ViewGraph, input: UIEnvironment.Input) -> Node {
        var environment = UIEnvironment()
        environment.input = input
        graph.install(root:
            ScrollView(.vertical) {
                Column {
                    Text("a").frame(height: 100)
                    Text("b").frame(height: 100)
                    Text("c").frame(height: 100)
                }
            }
            .surfaceEnvironment(environment)
            .frame(height: 150)
        )
        graph.computeLayout(width: 200, height: 400)
        guard let scroll = nodes(graph.tree.root).first(where: {
            InteractionRegistryHolder.current?.handlers(for: $0).wheel != nil
        }) else {
            Issue.record("scroll node was not found")
            return graph.tree.root!
        }
        return scroll
    }

    @Test("Touch drag moves the content and releases into scroll physics")
    func touchDrag() {
        GlobalTestLock.locked {
            let registry = InteractionRegistry()
            InteractionRegistryHolder.current = registry
            let capture = PointerCapture()
            PointerCaptureHolder.current = capture
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            let scroll = install(graph, input: [.touch])
            let handlers = registry.handlers(for: scroll)
            guard let pointer = handlers.pointer, let motion = handlers.motion else {
                Issue.record("scroll handlers were not registered")
                return
            }
            let origin = scroll.absoluteOrigin
            let x = Float(origin.x) + 80
            let y = Float(origin.y) + 80
            _ = pointer(MouseButtonEvent(button: .left, x: x, y: y, clicks: 1), .down, .target)
            _ = motion(MouseMotionEvent(x: x, y: y - 80, deltaX: 0, deltaY: -80), .target)
            _ = pointer(MouseButtonEvent(button: .left, x: x, y: y - 80, clicks: 1), .up, .target)
            #expect(scroll.contentOffset.y > 0)
            #expect(capture.target == nil)
        }
    }

    @Test("Keyboard Page/Home/End scrolls a focused viewport")
    func keyboard() {
        GlobalTestLock.locked {
            let registry = InteractionRegistry()
            InteractionRegistryHolder.current = registry
            let focus = FocusChain()
            FocusChainHolder.current = focus
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            let scroll = install(graph, input: [.pointer, .keyboard])
            focus.focus(scroll)
            guard let key = registry.handlers(for: scroll).key else {
                Issue.record("scroll key handler was not registered")
                return
            }
            func press(_ code: UInt32) {
                _ = key(KeyEvent(scancode: code, keycode: 0, modifiers: [], isRepeat: false), .target)
            }
            press(Scancode.pageDown)
            #expect(scroll.contentOffset.y > 0)
            let pageOffset = scroll.contentOffset.y
            press(Scancode.end)
            #expect(scroll.contentOffset.y > pageOffset)
            press(Scancode.home)
            #expect(scroll.contentOffset.y == 0)
        }
    }

    @Test("Desktop pointer drag does not scroll content")
    func pointerDragIgnored() {
        GlobalTestLock.locked {
            let registry = InteractionRegistry()
            InteractionRegistryHolder.current = registry
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            let scroll = install(graph, input: [.pointer, .keyboard])
            let handlers = registry.handlers(for: scroll)
            guard let pointer = handlers.pointer, let motion = handlers.motion else {
                Issue.record("scroll handlers were not registered")
                return
            }
            let origin = scroll.absoluteOrigin
            let x = Float(origin.x) + 80
            let y = Float(origin.y) + 80
            _ = pointer(MouseButtonEvent(button: .left, x: x, y: y, clicks: 1), .down, .target)
            _ = motion(MouseMotionEvent(x: x, y: y - 80, deltaX: 0, deltaY: -80), .target)
            _ = pointer(MouseButtonEvent(button: .left, x: x, y: y - 80, clicks: 1), .up, .target)
            #expect(scroll.contentOffset.y == 0)
        }
    }
}
