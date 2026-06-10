import Testing
#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
import EngineKernel
import GuavaUIRuntime
@testable import GuavaUICompose

/// Regression tests for the "dropdown/button dead after scrolling" class of
/// bugs: any absolute-origin walk that sums ancestor `frame.origin` without
/// subtracting ancestor `contentOffset` reports scrolled controls at their
/// unscrolled position. Button's release-inside check then cancels every
/// click, and the popover overlay registers at the wrong screen position.
@Suite("Scrolled control clicks", .serialized)
struct ScrolledControlClickTests: GuavaUIComposeSerializedSuite {

    private final class Counter {
        var taps = 0
    }

    private final class SelectionStore {
        var value = "a"
    }

    // MARK: - Helpers

    private func firstNode(in root: Node?, where predicate: (Node) -> Bool) -> Node? {
        guard let root else { return nil }
        if predicate(root) { return root }
        for child in root.children {
            if let match = firstNode(in: child, where: predicate) {
                return match
            }
        }
        return nil
    }

    /// Window-space origin: parent-local frames composed down the chain with
    /// every ancestor's scroll offset applied (children render translated by
    /// `-contentOffset`).
    private func visualOrigin(of node: Node) -> CGPoint {
        var origin = node.frame.origin
        var current = node.parent
        while let parent = current {
            origin.x += parent.frame.origin.x - parent.contentOffset.x
            origin.y += parent.frame.origin.y - parent.contentOffset.y
            current = parent.parent
        }
        return origin
    }

    private func click(_ dispatcher: EventDispatcher, x: CGFloat, y: CGFloat) {
        let event = MouseButtonEvent(button: .left, x: Float(x), y: Float(y), clicks: 1)
        dispatcher.dispatch(.mouseButtonDown(event))
        dispatcher.dispatch(.mouseButtonUp(event))
    }

    private struct ScrolledButtonHarness: View {
        let counter: Counter

        var body: some View {
            ScrollView(.vertical) {
                Column(alignment: .leading, spacing: 0) {
                    Text("header").frame(width: 200, height: 100)
                    Button(action: { counter.taps += 1 }) {
                        Text("Target")
                    }
                    .frame(width: 200, height: 30)
                    Text("tail").frame(width: 200, height: 300)
                }
            }
            .frame(width: 220, height: 160)
        }
    }

    @Test("Button inside a scrolled ScrollView fires on click at its visual position")
    func scrolledButtonClickFires() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        let capture = PointerCapture()
        let focus = FocusChain()
        InteractionRegistryHolder.current = registry
        PointerCaptureHolder.current = capture
        FocusChainHolder.current = focus
        defer {
            InteractionRegistryHolder.current = nil
            PointerCaptureHolder.current = nil
            FocusChainHolder.current = nil
        }

        let tree = NodeTree()
        let recomposer = Recomposer()
        let graph = ViewGraph(tree: tree, recomposer: recomposer)
        let counter = Counter()
        graph.install(root: ScrolledButtonHarness(counter: counter))
        graph.computeLayout(width: 220, height: 160)

        let scrollView = firstNode(in: tree.root, where: { $0.clipsToBounds })!
        scrollView.contentOffset = CGPoint(x: 0, y: 90)

        let button = firstNode(in: tree.root, where: {
            $0.attachments[ButtonHost.pressedKey] != nil
        })!
        let origin = visualOrigin(of: button)
        // Sanity: the button scrolled up into the viewport and is visible.
        #expect(origin.y < 160)

        let dispatcher = EventDispatcher(tree: tree,
                                         interactions: registry,
                                         capture: capture,
                                         focusChain: focus)
        click(dispatcher,
              x: origin.x + button.frame.width / 2,
              y: origin.y + button.frame.height / 2)

        #expect(counter.taps == 1)
    } }

    private struct ScrolledSelectHarness: View {
        let store: SelectionStore

        var body: some View {
            LayerRoot {
                ScrollView(.vertical) {
                    Column(alignment: .leading, spacing: 0) {
                        Text("header").frame(width: 200, height: 100)
                        Select(selection: Binding(get: { store.value },
                                                  set: { store.value = $0 }),
                               options: [
                                   SelectOption(value: "a", label: "Alpha"),
                                   SelectOption(value: "b", label: "Beta"),
                               ],
                               width: 160)
                        Text("tail").frame(width: 200, height: 300)
                    }
                }
                .frame(width: 240, height: 160)
            } portals: {
                PortalHost()
            }
        }
    }

    @Test("Select inside a scrolled ScrollView opens its menu at the trigger")
    func scrolledSelectOpensAtTrigger() { GlobalTestLock.locked {
        PortalStoreHolder.current.clear()
        defer { PortalStoreHolder.current.clear() }

        let registry = InteractionRegistry()
        let capture = PointerCapture()
        let focus = FocusChain()
        InteractionRegistryHolder.current = registry
        PointerCaptureHolder.current = capture
        FocusChainHolder.current = focus
        defer {
            InteractionRegistryHolder.current = nil
            PointerCaptureHolder.current = nil
            FocusChainHolder.current = nil
        }

        let tree = NodeTree()
        let recomposer = Recomposer()
        let graph = ViewGraph(tree: tree, recomposer: recomposer)
        let store = SelectionStore()
        graph.install(root: ScrolledSelectHarness(store: store))
        graph.computeLayout(width: 240, height: 200)

        let scrollView = firstNode(in: tree.root, where: { $0.clipsToBounds })!
        scrollView.contentOffset = CGPoint(x: 0, y: 90)

        let trigger = firstNode(in: tree.root, where: {
            $0.attachments[ButtonHost.pressedKey] != nil
        })!
        let triggerOrigin = visualOrigin(of: trigger)

        let dispatcher = EventDispatcher(tree: tree,
                                         interactions: registry,
                                         capture: capture,
                                         focusChain: focus)
        click(dispatcher,
              x: triggerOrigin.x + trigger.frame.width / 2,
              y: triggerOrigin.y + trigger.frame.height / 2)
        while recomposer.commitAll() {}
        graph.computeLayout(width: 240, height: 200)

        // The trigger click must open the menu even though the ScrollView is
        // scrolled (release-inside check has to account for contentOffset)…
        #expect(PortalStoreHolder.current.entries.count == 1)

        // …and the overlay must register at the trigger's on-screen position,
        // not its unscrolled layout position.
        guard let entry = PortalStoreHolder.current.entries.first else { return }
        guard let overlayHost = firstNode(in: tree.root, where: {
            $0.firstResource(PortalResource.self) != nil
        }), let popoverBox = overlayHost.parent else {
            Issue.record("popover overlay host was not materialized")
            return
        }
        let boxOrigin = visualOrigin(of: popoverBox)
        let expected = CGPoint(x: boxOrigin.x, y: boxOrigin.y + popoverBox.frame.height)
        #expect(abs(entry.position.x - expected.x) < 0.5)
        #expect(abs(entry.position.y - expected.y) < 0.5)
    } }

    // MARK: - Editor-inspector integration

    private final class InspectorModel {
        var shape = "box"
        var mode = "static"
    }

    /// Mirrors the editor wiring: every model write recomposes the whole panel
    /// (like the editor's StoreScope), rebuilding fresh Select views/bindings.
    private struct InspectorHarness: View {
        let model: InspectorModel
        @State var revision: Int = 0

        private func binding(_ keyPath: ReferenceWritableKeyPath<InspectorModel, String>) -> Binding<String> {
            Binding(get: { model[keyPath: keyPath] },
                    set: { model[keyPath: keyPath] = $0
                           revision += 1 })
        }

        var body: some View {
            let _ = revision
            LayerRoot {
                Panel("Inspector") {
                    PropertyGrid([
                        PropertyGridSection(id: "physics", title: "Physics", rows: [
                            PropertyGridRow(id: "shape", label: "Shape") {
                                Select(selection: binding(\.shape),
                                       options: [
                                           SelectOption(value: "box", label: "Box"),
                                           SelectOption(value: "sphere", label: "Sphere"),
                                           SelectOption(value: "capsule", label: "Capsule"),
                                       ],
                                       width: 150)
                                    .debugName("select-shape")
                            },
                            PropertyGridRow(id: "mode", label: "Mode") {
                                Select(selection: binding(\.mode),
                                       options: [
                                           SelectOption(value: "static", label: "Static"),
                                           SelectOption(value: "dynamic", label: "Dynamic"),
                                       ],
                                       width: 150)
                                    .debugName("select-mode")
                            },
                        ], isCollapsible: true),
                    ], labelWidth: 88, rowHeight: 24)
                }
                .frame(width: 320, height: 280)
            } portals: {
                PortalHost()
            }
        }
    }

    @Test("Inspector-style Selects reopen after picking an option")
    func inspectorSelectsReopenAfterSelection() { GlobalTestLock.locked {
        PortalStoreHolder.current.clear()
        defer { PortalStoreHolder.current.clear() }

        let registry = InteractionRegistry()
        let capture = PointerCapture()
        let focus = FocusChain()
        InteractionRegistryHolder.current = registry
        PointerCaptureHolder.current = capture
        FocusChainHolder.current = focus
        defer {
            InteractionRegistryHolder.current = nil
            PointerCaptureHolder.current = nil
            FocusChainHolder.current = nil
        }

        let tree = NodeTree()
        let recomposer = Recomposer()
        let graph = ViewGraph(tree: tree, recomposer: recomposer)
        let model = InspectorModel()
        graph.install(root: InspectorHarness(model: model))

        func settle() {
            var passes = 0
            while recomposer.commitAll() {
                passes += 1
                if passes > 100 {
                    Issue.record("recomposer did not settle — runaway invalidation loop")
                    return
                }
            }
            graph.computeLayout(width: 320, height: 280)
        }
        settle()

        func selectTriggers() -> [Node] {
            ["select-shape", "select-mode"].compactMap { name in
                guard let host = firstNode(in: tree.root, where: {
                    $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == name
                }) else { return nil }
                return firstNode(in: host, where: {
                    $0.attachments[ButtonHost.pressedKey] != nil
                })
            }
        }

        let dispatcher = EventDispatcher(tree: tree,
                                         interactions: registry,
                                         capture: capture,
                                         focusChain: focus)

        func clickCenter(_ node: Node) {
            let origin = visualOrigin(of: node)
            click(dispatcher,
                  x: origin.x + node.frame.width / 2,
                  y: origin.y + node.frame.height / 2)
            settle()
        }

        func menuItemRow(id: AnyHashable) -> Node? {
            firstNode(in: tree.root, where: {
                $0.attachments["__menu_item_id"] as? AnyHashable == id
            })
        }

        let triggers = selectTriggers()
        #expect(triggers.count == 2)
        guard triggers.count == 2 else { return }

        // 1. Open the first dropdown.
        clickCenter(triggers[0])
        #expect(PortalStoreHolder.current.entries.count == 1)

        // 2. Pick "Sphere" — menu closes, model updates, panel recomposes.
        guard let sphereRow = menuItemRow(id: AnyHashable("sphere")) else {
            Issue.record("sphere menu item was not materialized")
            return
        }
        clickCenter(sphereRow)
        #expect(model.shape == "sphere")
        #expect(PortalStoreHolder.current.entries.count == 0)

        // 3. The same dropdown must reopen after the selection (the rebuild
        //    swapped @State storage; stale handler captures would write into
        //    dead storage and the menu would never appear again).
        clickCenter(selectTriggers()[0])
        #expect(PortalStoreHolder.current.entries.count == 1)
        #expect(menuItemRow(id: AnyHashable("capsule")) != nil)

        // 4. Close it again via the trigger, then the second dropdown must
        //    open as well.
        clickCenter(selectTriggers()[0])
        #expect(PortalStoreHolder.current.entries.count == 0)
        clickCenter(selectTriggers()[1])
        #expect(PortalStoreHolder.current.entries.count == 1)
        #expect(menuItemRow(id: AnyHashable("dynamic")) != nil)
    } }
}
