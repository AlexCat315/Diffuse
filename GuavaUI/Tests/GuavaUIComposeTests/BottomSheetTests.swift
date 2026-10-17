import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Bottom sheet", .serialized)
struct BottomSheetTests: GuavaUIComposeSerializedSuite {
    private func nodes(_ node: Node?) -> [Node] {
        guard let node else { return [] }
        return [node] + node.children.flatMap { nodes($0) }
    }

    private func named(_ name: String, in graph: ViewGraph) throws -> Node {
        try #require(nodes(graph.tree.root).first {
            $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == name
        })
    }

    private func settle(_ graph: ViewGraph, width: Float = 390, height: Float = 600) {
        for _ in 0..<5 {
            graph.recomposer.commitAll()
            graph.computeLayout(width: width, height: height)
            AnimatorScheduler.current.tick(deltaTime: 1)
        }
    }

    private func withScene(_ test: (ViewGraph, InteractionRegistry, FocusChain, PointerCapture) -> Void) {
        GlobalTestLock.locked {
            let oldRegistry = InteractionRegistryHolder.current
            let oldFocus = FocusChainHolder.current
            let oldCapture = PointerCaptureHolder.current
            let oldPortal = PortalStoreHolder.current
            let oldText = TextEnvironmentHolder.current
            let registry = InteractionRegistry(), focus = FocusChain(), capture = PointerCapture()
            let portal = PortalStore()
            InteractionRegistryHolder.current = registry
            FocusChainHolder.current = focus
            PointerCaptureHolder.current = capture
            PortalStoreHolder.current = portal
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer {
                InteractionRegistryHolder.current = oldRegistry
                FocusChainHolder.current = oldFocus
                PointerCaptureHolder.current = oldCapture
                PortalStoreHolder.current = oldPortal
                TextEnvironmentHolder.current = oldText
            }
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            test(graph, registry, focus, capture)
            graph.install(root: EmptyView())
            AnimatorScheduler.current.tick(deltaTime: 1)
        }
    }

    private func drag(_ handle: Node, deltaY: Float, graph: ViewGraph,
                      registry: InteractionRegistry, focus: FocusChain,
                      capture: PointerCapture) {
        let frame = handle.absoluteFrame
        let x = Float(frame.midX), y = Float(frame.midY)
        let dispatcher = EventDispatcher(tree: graph.tree, interactions: registry,
                                         capture: capture, focusChain: focus)
        let down = MouseButtonEvent(button: .left, x: x, y: y, clicks: 1)
        dispatcher.dispatch(.mouseButtonDown(down))
        graph.recomposer.commitAll()
        dispatcher.dispatch(.mouseMotion(MouseMotionEvent(x: x, y: y + deltaY, deltaX: 0, deltaY: deltaY)))
        graph.recomposer.commitAll()
        dispatcher.dispatch(.mouseButtonUp(MouseButtonEvent(button: .left, x: x, y: y + deltaY,
                                                             clicks: 1)))
        graph.recomposer.commitAll()
    }

    @Test("Dragging the handle down dismisses the first detent")
    func dragDismisses() {
        withScene { graph, registry, focus, capture in
            var open = true
            var surface = UIEnvironment()
            surface.viewport.width = 390
            surface.input = [.touch]
            graph.install(root: LayerRoot {
                BottomSheet(isPresented: Binding(get: { open }, set: { open = $0 }),
                            configure: { $0.detents = [200, 400]; $0.dragDismissThreshold = 60 }) {
                    Box {}.frame(width: .percent(100), height: .percent(100))
                }.surfaceEnvironment(surface)
            })
            settle(graph)
            guard let handle = try? named("bottom-sheet-handle", in: graph) else {
                Issue.record("bottom sheet handle was not mounted")
                return
            }
            drag(handle, deltaY: 100, graph: graph, registry: registry, focus: focus, capture: capture)
            settle(graph)
            #expect(open == false)
        }
    }

    @Test("Dragging up expands the sheet to the next detent")
    func dragExpands() {
        withScene { graph, registry, focus, capture in
            var surface = UIEnvironment()
            surface.viewport.width = 390
            surface.input = [.touch]
            graph.install(root: LayerRoot {
                BottomSheet(isPresented: .constant(true),
                            configure: { $0.detents = [200, 400]; $0.dragDismissThreshold = 60 }) {
                    Box {}.frame(width: .percent(100), height: .percent(100))
                }.surfaceEnvironment(surface)
            })
            settle(graph)
            guard let handle = try? named("bottom-sheet-handle", in: graph) else {
                Issue.record("bottom sheet handle was not mounted")
                return
            }
            drag(handle, deltaY: -100, graph: graph, registry: registry, focus: focus, capture: capture)
            settle(graph)
            let content = try? named("bottom-sheet-content", in: graph)
            #expect(content?.frame.height == 400)
        }
    }

    @Test("Expanded surfaces degrade to a centered dialog-sized panel")
    func expandedSurface() {
        withScene { graph, _, _, _ in
            var surface = UIEnvironment()
            surface.viewport.width = 1280
            surface.viewport.height = 800
            surface.input = [.pointer, .keyboard]
            graph.install(root: LayerRoot {
                BottomSheet(isPresented: .constant(true),
                            configure: { $0.detents = [260]; $0.dialogWidth = 560 }) {
                    Box {}.frame(width: .percent(100), height: .percent(100))
                }.surfaceEnvironment(surface)
            })
            settle(graph, width: 1280, height: 800)
            let content = try? named("bottom-sheet-content", in: graph)
            #expect(content?.frame.width == 560)
            #expect(content?.frame.height == 260)
        }
    }
}
