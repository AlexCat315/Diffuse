import Foundation
import Testing
import EngineKernel
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Menu pointer routing", .serialized)
struct MenuPointerRoutingTests: GuavaUIComposeSerializedSuite {
    private final class Probe { var actions = 0 }
    private struct Item: Identifiable { let id: Int }

    private struct Harness: View {
        let probe: Probe
        @State var selection: Int?
        @State var shown = false
        var body: some View {
            let _ = FocusChainHolder.current?.commandTarget
            LayerRoot {
                Column(spacing: 0) {
                    Popover(isPresented: $shown, width: 160) {
                        Text("Open").frame(width: 80, height: 28)
                    } content: {
                        Menu([.item(MenuItem(id: "popover-action", title: "Action") {
                            probe.actions += 1
                        })], width: 160, onItemActivated: { shown = false })
                    }
                    .id("popover")
                    .flex(0)
                    Tree([Item(id: 1)], id: \.id, children: { _ in [] }, selection: $selection) { item, _, _, _ in
                        Text("Row").frame(height: 30)
                            .contextMenu(onOpen: { selection = item.id }, entries: {
                                [.item(MenuItem(id: "context-action", title: "Action") {
                                    probe.actions += 1
                                })]
                            })
                    }
                    .id("tree")
                    .flex()
                }
                .flex()
            }
        }
    }

    private func withGraph(_ work: (ViewGraph, EventDispatcher, InteractionRegistry, Probe) throws -> Void) rethrows {
        try GlobalTestLock.locked {
            let oldRegistry = InteractionRegistryHolder.current
            let oldCapture = PointerCaptureHolder.current
            let oldFocus = FocusChainHolder.current
            let oldStore = PortalStoreHolder.current
            let oldText = TextEnvironmentHolder.current
            let registry = InteractionRegistry()
            let capture = PointerCapture()
            let focus = FocusChain()
            InteractionRegistryHolder.current = registry
            PointerCaptureHolder.current = capture
            FocusChainHolder.current = focus
            PortalStoreHolder.current = PortalStore()
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make(size: 12, lineHeight: 16)
            defer {
                InteractionRegistryHolder.current = oldRegistry
                PointerCaptureHolder.current = oldCapture
                FocusChainHolder.current = oldFocus
                PortalStoreHolder.current = oldStore
                TextEnvironmentHolder.current = oldText
            }
            let tree = NodeTree()
            let graph = ViewGraph(tree: tree, recomposer: Recomposer())
            let dispatcher = EventDispatcher(tree: tree, interactions: registry, capture: capture, focusChain: focus)
            try work(graph, dispatcher, registry, Probe())
        }
    }

    private func nodes(_ node: Node?) -> [Node] {
        guard let node else { return [] }
        return [node] + node.children.flatMap { nodes($0) }
    }
    private func settle(_ graph: ViewGraph) {
        for _ in 0..<5 {
            graph.recomposer.commitAll()
            graph.computeLayout(width: 400, height: 300)
        }
    }
    private func click(_ frame: CGRect, button: MouseButton = .left,
                       graph: ViewGraph, dispatcher: EventDispatcher) {
        let event = MouseButtonEvent(button: button, x: Float(frame.midX), y: Float(frame.midY), clicks: 1)
        dispatcher.dispatch(.mouseButtonDown(event))
        settle(graph)
        dispatcher.dispatch(.mouseButtonUp(event))
        settle(graph)
    }

    @Test("Popover remains open across focus-driven parent updates and activates once")
    func popoverFocusUpdate() throws { try withGraph { graph, dispatcher, _, probe in
        graph.install(root: Harness(probe: probe))
        settle(graph)
        let trigger = try #require(nodes(graph.tree.root).first { $0.attachments[ButtonHost.markerKey] != nil })
        click(trigger.absoluteFrame, graph: graph, dispatcher: dispatcher)
        #expect(PortalStoreHolder.current.entries.count == 1)
        let item = try #require(nodes(graph.tree.root).first { $0.attachments["__menu_item_id"] as? AnyHashable == AnyHashable("popover-action") })
        click(item.absoluteFrame, graph: graph, dispatcher: dispatcher)
        #expect(probe.actions == 1)
        #expect(PortalStoreHolder.current.entries.isEmpty)
    } }

    @Test("Right-click selecting a tree row retains and activates its context menu")
    func contextSelectionUpdate() throws { try withGraph { graph, dispatcher, _, probe in
        graph.install(root: Harness(probe: probe))
        settle(graph)
        let row = try #require(nodes(graph.tree.root).first { $0.firstResource(PortalResource.self) != nil })
        click(row.absoluteFrame, button: .right, graph: graph, dispatcher: dispatcher)
        #expect(PortalStoreHolder.current.entries.count == 1)
        let item = try #require(nodes(graph.tree.root).first { $0.attachments["__menu_item_id"] as? AnyHashable == AnyHashable("context-action") })
        click(item.absoluteFrame, graph: graph, dispatcher: dispatcher)
        #expect(probe.actions == 1)
        #expect(PortalStoreHolder.current.entries.isEmpty)
    } }

    @Test("Buttons inside selectable rows receive their own clicks", arguments: [false, true])
    func nestedButton(inTree: Bool) throws { try withGraph { graph, dispatcher, _, probe in
        if inTree {
            graph.install(root: Tree([Item(id: 1)], id: \.id, children: { _ in [] }) { _, _, _, _ in
                Button("Action") { probe.actions += 1 }
            })
        } else {
            graph.install(root: List([Item(id: 1)], selection: .constant(nil)) { _, _ in
                Button("Action") { probe.actions += 1 }
            })
        }
        settle(graph)
        let button = try #require(nodes(graph.tree.root).first { $0.attachments[ButtonHost.markerKey] != nil })
        click(button.absoluteFrame, graph: graph, dispatcher: dispatcher)
        #expect(probe.actions == 1)
    } }
}
