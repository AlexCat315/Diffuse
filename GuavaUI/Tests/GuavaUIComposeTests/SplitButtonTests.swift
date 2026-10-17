import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Split button", .serialized)
struct SplitButtonTests: GuavaUIComposeSerializedSuite {
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

    private func buttons(_ graph: ViewGraph) -> [Node] {
        nodes(graph.tree.root).filter { $0.attachments[ButtonHost.markerKey] != nil }
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

    @Test("Primary and menu zones run their own actions")
    func zones() {
        withScene { graph, registry, focus, capture, portal in
            var primaryRuns = 0
            var menuRuns = 0
            graph.install(root: LayerRoot {
                SplitButton("Save", entries: [
                    .item(MenuItem(id: "saveAs", title: "Save as") { menuRuns += 1 }),
                ], action: { primaryRuns += 1 })
            })
            settle(graph)
            let hosts = buttons(graph)
            #expect(hosts.count == 2)
            guard hosts.count == 2 else { return }
            click(hosts[0], graph: graph, registry: registry, focus: focus, capture: capture)
            settle(graph)
            #expect(primaryRuns == 1)
            click(hosts[1], graph: graph, registry: registry, focus: focus, capture: capture)
            settle(graph)
            #expect(portal.entries.count == 1)
            guard let item = nodes(graph.tree.root).first(where: { $0.accessibility?.label == "Save as" }) else {
                Issue.record("split button menu item was not mounted")
                return
            }
            click(item, graph: graph, registry: registry, focus: focus, capture: capture)
            settle(graph)
            #expect(menuRuns == 1)
            #expect(portal.entries.isEmpty)
        }
    }

    @Test("Disabled SplitButton does not run either zone")
    func disabled() {
        withScene { graph, registry, focus, capture, portal in
            var runs = 0
            graph.install(root: LayerRoot {
                SplitButton("Save", entries: [
                    .item(MenuItem(id: "saveAs", title: "Save as") { runs += 1 }),
                ], isEnabled: false, action: { runs += 1 })
            })
            settle(graph)
            let hosts = buttons(graph)
            guard hosts.count == 2 else {
                Issue.record("split button hosts were not mounted")
                return
            }
            click(hosts[0], graph: graph, registry: registry, focus: focus, capture: capture)
            click(hosts[1], graph: graph, registry: registry, focus: focus, capture: capture)
            settle(graph)
            #expect(runs == 0)
            #expect(portal.entries.isEmpty)
        }
    }

    @Test("The pair owns one Tab stop and Left/Right switches zones")
    func rovingZones() {
        withScene { graph, registry, focus, capture, _ in
            graph.install(root: LayerRoot {
                SplitButton("Save", entries: [.item(MenuItem(id: "saveAs", title: "Save as") {})],
                            action: {})
            })
            settle(graph)
            let hosts = buttons(graph)
            #expect(hosts.count == 2)
            guard hosts.count == 2 else { return }
            #expect(hosts[0].isTabStop && !hosts[1].isTabStop)
            focus.focus(hosts[0])
            let dispatcher = EventDispatcher(tree: graph.tree, interactions: registry,
                                             capture: capture, focusChain: focus)
            dispatcher.dispatch(.keyDown(KeyEvent(scancode: Scancode.arrowRight, keycode: 0,
                                                  modifiers: [], isRepeat: false)))
            settle(graph)
            #expect(focus.focused === hosts[1])
            #expect(!hosts[0].isTabStop && hosts[1].isTabStop)
            dispatcher.dispatch(.keyDown(KeyEvent(scancode: Scancode.arrowLeft, keycode: 0,
                                                  modifiers: [], isRepeat: false)))
            settle(graph)
            #expect(focus.focused === hosts[0])
            #expect(hosts[0].isTabStop && !hosts[1].isTabStop)
        }
    }
}
