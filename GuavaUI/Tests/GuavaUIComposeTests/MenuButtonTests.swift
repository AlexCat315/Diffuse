import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Menu button", .serialized)
struct MenuButtonTests: GuavaUIComposeSerializedSuite {
    private func nodes(_ node: Node?) -> [Node] {
        guard let node else { return [] }
        return [node] + node.children.flatMap { nodes($0) }
    }

    private func withScene(_ test: (ViewGraph, InteractionRegistry, FocusChain, PointerCapture, PortalStore) -> Void) {
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
            test(graph, registry, focus, capture, portal)
            graph.install(root: EmptyView())
            AnimatorScheduler.current.tick(deltaTime: 1)
        }
    }

    private func settle(_ graph: ViewGraph) {
        for _ in 0..<5 {
            graph.recomposer.commitAll()
            graph.computeLayout(width: 800, height: 600)
            AnimatorScheduler.current.tick(deltaTime: 1)
        }
    }

    private func click(_ node: Node, graph: ViewGraph, registry: InteractionRegistry,
                       focus: FocusChain, capture: PointerCapture) {
        let frame = node.absoluteFrame
        let dispatcher = EventDispatcher(tree: graph.tree, interactions: registry,
                                         capture: capture, focusChain: focus)
        let point = MouseButtonEvent(button: .left, x: Float(frame.midX), y: Float(frame.midY), clicks: 1)
        dispatcher.dispatch(.mouseButtonDown(point))
        graph.recomposer.commitAll()
        dispatcher.dispatch(.mouseButtonUp(point))
        graph.recomposer.commitAll()
    }

    @Test("MenuButton opens its menu, runs the item and closes")
    func opensRunsAndCloses() {
        withScene { graph, registry, focus, capture, portal in
            var runs = 0
            graph.install(root: LayerRoot {
                MenuButton("Options", entries: [
                    .item(MenuItem(id: "save", title: "Save") { runs += 1 }),
                    .item(MenuItem(id: "export", title: "Export") { runs += 10 }),
                ])
            })
            settle(graph)
            guard let trigger = nodes(graph.tree.root).first(where: {
                $0.attachments[ButtonHost.markerKey] != nil
            }) else {
                Issue.record("menu button trigger was not mounted")
                return
            }
            click(trigger, graph: graph, registry: registry, focus: focus, capture: capture)
            settle(graph)
            #expect(portal.entries.count == 1)
            guard let item = nodes(graph.tree.root).first(where: {
                $0.accessibility?.label == "Save"
            }) else {
                Issue.record("menu item was not mounted")
                return
            }
            click(item, graph: graph, registry: registry, focus: focus, capture: capture)
            settle(graph)
            #expect(runs == 1)
            #expect(portal.entries.isEmpty)
        }
    }

    @Test("Disabled MenuButton does not open")
    func disabledDoesNotOpen() {
        withScene { graph, registry, focus, capture, portal in
            graph.install(root: LayerRoot {
                MenuButton("Options", entries: [.item(MenuItem(id: "save", title: "Save") {})],
                           isEnabled: false)
            })
            settle(graph)
            guard let trigger = nodes(graph.tree.root).first(where: {
                $0.attachments[ButtonHost.markerKey] != nil
            }) else {
                Issue.record("menu button trigger was not mounted")
                return
            }
            click(trigger, graph: graph, registry: registry, focus: focus, capture: capture)
            settle(graph)
            #expect(portal.entries.isEmpty)
        }
    }
}
