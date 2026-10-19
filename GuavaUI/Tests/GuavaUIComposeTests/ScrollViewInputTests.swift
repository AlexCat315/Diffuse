import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("ScrollView input", .serialized)
struct ScrollViewInputTests: GuavaUIComposeSerializedSuite {
    @Test("Scroll content accepts conditional branches and repeated children", arguments: [false, true])
    func contentBuilder(empty: Bool) throws { try GlobalTestLock.locked {
        let old = TextEnvironmentHolder.current; TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
        defer { TextEnvironmentHolder.current = old }
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: ScrollView(.vertical) {
            if empty {
                AnyView(Text("Empty document"))
            } else {
                AnyView(Column {
                    (0..<3).map { AnyView(Text("Section \($0)").frame(height: 100)) }
                })
            }
        }.frame(width: 200, height: 120))
        graph.computeLayout(width: 200, height: 120)
        let labels = nodes(graph.tree.root).compactMap { $0.accessibility?.label }.filter { !$0.isEmpty }
        #expect(labels.contains("Empty document") == empty)
        #expect(labels.filter { $0.hasPrefix("Section ") }.count == (empty ? 0 : 3))
        #expect(nodes(graph.tree.root).allSatisfy { $0.frame.width.isFinite && $0.frame.height.isFinite })
        graph.install(root: EmptyView())
    } }

    @Test("Global scrollbar hit lanes cannot capture adjacent controls or cross an ancestor clip", arguments: [false, true])
    func chromeBounds(clipped: Bool) throws {
        try GlobalTestLock.locked {
            let old = TextEnvironmentHolder.current; TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = old }
            let context = PlatformInputContext()
            try context.withCurrent {
                let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                var calls = 0
                let pane: Float = clipped ? 80 : 100
                graph.install(root: Box(direction: .row, alignItems: .stretch) {
                    Box(direction: .column, alignItems: .flexStart) {
                        ScrollView(.vertical) { Box {}.frame(height: 600) }.frame(width: 100, height: 100)
                    }.frame(width: pane).flex(0, shrink: 0).clipped()
                    Button("Adjacent") { calls += 1 }.frame(width: 44, height: 100).flex(0, shrink: 0)
                }.frame(width: pane + 44, height: 100))
                defer { graph.install(root: EmptyView()) }
                for _ in 0..<4 { graph.recomposer.commitAll(); graph.computeLayout(width: pane + 44, height: 100) }
                let dispatcher = EventDispatcher(tree: graph.tree, interactions: context.interactions,
                    capture: context.pointerCapture, focusChain: context.focusChain)
                let event = MouseButtonEvent(button: .left, x: pane + 2, y: 50, clicks: 1)
                dispatcher.dispatch(.mouseButtonDown(event))
                #expect(context.pointerCapture.target?.accessibility?.role == .button)
                dispatcher.dispatch(.mouseButtonUp(event))
                #expect(calls == 1 && context.pointerCapture.target == nil)
                if !clipped {
                    dispatcher.dispatch(.mouseButtonDown(.init(button: .left, x: 96, y: 50, clicks: 1)))
                    #expect(context.pointerCapture.target?.accessibility?.role == .scrollArea)
                    dispatcher.dispatch(.mouseButtonUp(.init(button: .left, x: 96, y: 150, clicks: 1)))
                    #expect(context.pointerCapture.target == nil)
                }
            }
        }
    }

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
