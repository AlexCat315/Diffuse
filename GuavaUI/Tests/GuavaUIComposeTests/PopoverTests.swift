import Testing
#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
import EngineKernel
import GuavaUIRuntime
@testable import GuavaUICompose

private struct _PopoverProbe: _PrimitiveView {
    let id: String
    let width: Float
    let height: Float

    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = false
        return node
    }

    func _updateNode(_ node: Node) {
        node.attachments["probeID"] = id
    }

    func _makeLayoutNode() -> LayoutNode? {
        LayoutNode()
    }

    func _updateLayout(_ layout: LayoutNode) {
        layout.width = width
        layout.height = height
    }
}

@Suite("Popover")
struct PopoverTests: GuavaUIComposeSerializedSuite {
    private final class ActionBox {
        var fired = 0
    }

    struct Harness: View {
        @State var isPresented: Bool = false

        var body: some View {
            Column(alignment: .leading, spacing: 8) {
                Popover(isPresented: $isPresented,
                        width: 120) {
                    _PopoverProbe(id: "trigger", width: 80, height: 20)
                } content: {
                    _PopoverProbe(id: "menu", width: 120, height: 60)
                }

                _PopoverProbe(id: "sibling", width: 80, height: 20)
            }
        }
    }

    @Test("Opening Popover does not move following siblings")
    func openingPopoverDoesNotAffectSiblingLayout() { GlobalTestLock.locked {
        // Presenting the popover registers into the process-wide PortalRegistry,
        // so this case must hold the lock and clear it like the others —
        // otherwise it races the other Popover/Portal tests.
        PortalRegistry.clear()
        defer { PortalRegistry.clear() }

        let tree = NodeTree()
        let recomposer = Recomposer()
        let graph = ViewGraph(tree: tree, recomposer: recomposer)
        let harness = Harness()

        graph.install(root: harness)
        graph.computeLayout(width: 240, height: 200)

        let initialSiblingY = findProbe(id: "sibling", in: tree.root)?.frame.origin.y
        #expect(initialSiblingY != nil)

        harness.$isPresented.wrappedValue = true
        recomposer.commitAll()
        graph.computeLayout(width: 240, height: 200)

        let expandedSiblingY = findProbe(id: "sibling", in: tree.root)?.frame.origin.y
        #expect(expandedSiblingY == initialSiblingY)
    } }

    private struct MenuHarness: View {
        let box: ActionBox
        @State var isPresented: Bool = false

        var body: some View {
            LayerRoot {
                Popover(isPresented: $isPresented,
                        width: 140) {
                    _PopoverProbe(id: "trigger", width: 80, height: 24)
                } content: {
                    Menu([
                        .item(MenuItem(id: "new-scene", title: "New Scene") {
                            box.fired += 1
                        })
                    ], width: 140)
                }
            } portals: {
                PortalHost()
            }
        }
    }

    private struct ReopenHarness: View {
        let box: ActionBox
        @State var isPresented: Bool = false

        var body: some View {
            LayerRoot {
                Popover(isPresented: $isPresented,
                        width: 140) {
                    _PopoverProbe(id: "trigger", width: 80, height: 24)
                } content: {
                    Menu([
                        .item(MenuItem(id: "reopen-item", title: "Item") {
                            box.fired += 1
                        })
                    ], width: 140, onItemActivated: {
                        isPresented = false
                    })
                }
            } portals: {
                PortalHost()
            }
        }
    }

    private struct ChurnHarness: View {
        let box: ActionBox
        @State var tick: Int = 0
        @State var isPresented: Bool = false

        var body: some View {
            LayerRoot {
                Column(alignment: .leading, spacing: 0) {
                    // Read `tick` so bumping it recomposes this scope (and thus
                    // re-runs the Popover) — mimicking the editor's per-frame
                    // StoreScope recomposition while a dropdown is open.
                    let _ = tick
                    Popover(isPresented: $isPresented,
                            width: 140) {
                        _PopoverProbe(id: "trigger", width: 80, height: 24)
                    } content: {
                        Menu([
                            .item(MenuItem(id: "churn-item", title: "Item") {
                                box.fired += 1
                            })
                        ], width: 140)
                    }
                }
            } portals: {
                PortalHost()
            }
        }
    }

    @Test("Popover survives frequent parent recomposition while open")
    func popoverSurvivesParentChurn() { GlobalTestLock.locked {
        PortalRegistry.clear()
        defer { PortalRegistry.clear() }

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
        let box = ActionBox()
        let root = ChurnHarness(box: box)
        graph.install(root: root)
        graph.computeLayout(width: 240, height: 180)

        let dispatcher = EventDispatcher(tree: tree,
                                         interactions: registry,
                                         capture: capture,
                                         focusChain: focus)
        dispatcher.inputScene = graph.inputScene

        func settle() { while recomposer.commitAll() {}; graph.computeLayout(width: 240, height: 180) }

        // Open.
        click(dispatcher, x: 10, y: 10); settle()
        #expect(PortalRegistry.entries.count == 1)
        #expect(!menuItemRows(in: tree.root, id: AnyHashable("churn-item")).isEmpty)

        // Churn the parent many times while the popover stays open.
        for _ in 0..<10 {
            root.$tick.wrappedValue += 1
            settle()
        }
        // The menu must still be present after the churn.
        #expect(PortalRegistry.entries.count == 1)
        #expect(!menuItemRows(in: tree.root, id: AnyHashable("churn-item")).isEmpty)

        // And the trigger must still toggle it closed, then reopen.
        click(dispatcher, x: 10, y: 10); settle()
        #expect(PortalRegistry.entries.count == 0)
        click(dispatcher, x: 10, y: 10); settle()
        #expect(PortalRegistry.entries.count == 1)
        #expect(!menuItemRows(in: tree.root, id: AnyHashable("churn-item")).isEmpty)
    } }

    private struct LeakHarness: View {
        let box: ActionBox
        @State var showPopover: Bool = true
        @State var isPresented: Bool = true

        var body: some View {
            LayerRoot {
                Column(alignment: .leading, spacing: 0) {
                    if showPopover {
                        Popover(isPresented: $isPresented,
                                width: 140) {
                            _PopoverProbe(id: "trigger", width: 80, height: 24)
                        } content: {
                            Menu([
                                .item(MenuItem(id: "leak-item", title: "Item") {
                                    box.fired += 1
                                })
                            ], width: 140)
                        }
                    }
                }
            } portals: {
                PortalHost()
            }
        }
    }

    @Test("Tearing down an open Popover does not leak its portal entry")
    func teardownOpenPopoverDoesNotLeak() { GlobalTestLock.locked {
        PortalRegistry.clear()
        defer { PortalRegistry.clear() }

        let tree = NodeTree()
        let recomposer = Recomposer()
        let graph = ViewGraph(tree: tree, recomposer: recomposer)
        let box = ActionBox()
        let root = LeakHarness(box: box)
        graph.install(root: root)
        graph.computeLayout(width: 240, height: 200)

        // Open popover materialised its overlay → one portal entry.
        #expect(PortalRegistry.entries.count == 1)

        // Remove the whole Popover from the tree while it is still "open".
        root.$showPopover.wrappedValue = false
        while recomposer.commitAll() {}
        graph.computeLayout(width: 240, height: 200)

        // The entry must be gone — a leaked entry leaves a phantom menu in the
        // shared portal layer that can intercept later clicks.
        #expect(PortalRegistry.entries.count == 0)
    } }

    private struct NestedPortalRootHarness: View {
        let box: ActionBox

        var body: some View {
            LayerRoot {
                NestedMenuHarness(box: box)
            } portals: {
                PortalHost()
            }
        }
    }

    private struct NestedMenuHarness: View {
        let box: ActionBox
        @State var isPresented: Bool = false

        var body: some View {
            Popover(isPresented: $isPresented,
                    width: 140) {
                _PopoverProbe(id: "nested-trigger", width: 80, height: 24)
            } content: {
                Menu([
                    .item(MenuItem(id: "nested-new-scene", title: "New Scene") {
                        box.fired += 1
                    })
                ], width: 140)
            }
        }
    }

    @Test("Popover menu item receives pointer activation through portal layer")
    func popoverMenuItemReceivesPointerActivation() { GlobalTestLock.locked {
        PortalRegistry.clear()
        defer { PortalRegistry.clear() }

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
        let box = ActionBox()
        graph.install(root: MenuHarness(box: box))
        graph.computeLayout(width: 240, height: 180)

        let dispatcher = EventDispatcher(tree: tree,
                                         interactions: registry,
                                         capture: capture,
                                         focusChain: focus)
        dispatcher.inputScene = graph.inputScene

        click(dispatcher, x: 10, y: 10)
        _ = recomposer.commitAll()
        graph.computeLayout(width: 240, height: 180)

        guard let menuItem = menuItemRows(in: tree.root, id: AnyHashable("new-scene"))
            .first
        else {
            Issue.record("menu item row was not materialized")
            return
        }

        click(dispatcher,
              x: Float(menuItem.origin.x + menuItem.node.frame.width * 0.5),
              y: Float(menuItem.origin.y + menuItem.node.frame.height * 0.5))

        #expect(box.fired == 1)
    } }

    @Test("Popover reopens after closing via a menu item")
    func popoverReopensAfterClose() { GlobalTestLock.locked {
        PortalRegistry.clear()
        defer { PortalRegistry.clear() }

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
        let box = ActionBox()
        graph.install(root: ReopenHarness(box: box))
        graph.computeLayout(width: 240, height: 180)

        let dispatcher = EventDispatcher(tree: tree,
                                         interactions: registry,
                                         capture: capture,
                                         focusChain: focus)
        dispatcher.inputScene = graph.inputScene

        // 1. Open.
        click(dispatcher, x: 10, y: 10)
        _ = recomposer.commitAll()
        graph.computeLayout(width: 240, height: 180)
        #expect(PortalRegistry.entries.count == 1)

        // 2. Close by activating the item.
        guard let item = menuItemRows(in: tree.root, id: AnyHashable("reopen-item")).first else {
            Issue.record("menu item row was not materialized on first open")
            return
        }
        click(dispatcher,
              x: Float(item.origin.x + item.node.frame.width * 0.5),
              y: Float(item.origin.y + item.node.frame.height * 0.5))
        _ = recomposer.commitAll()
        graph.computeLayout(width: 240, height: 180)
        #expect(box.fired == 1)
        #expect(PortalRegistry.entries.count == 0)

        // 3. Reopen — the regression: a portal entry must register again AND
        //    the menu must actually re-materialize in the node tree (a registry
        //    entry that PortalHost never re-renders would still be "stuck").
        click(dispatcher, x: 10, y: 10)
        _ = recomposer.commitAll()
        graph.computeLayout(width: 240, height: 180)
        #expect(PortalRegistry.entries.count == 1)
        #expect(!menuItemRows(in: tree.root, id: AnyHashable("reopen-item")).isEmpty)
        #expect(PointerCaptureHolder.current?.target == nil)
    } }

    @Test("Popover reopens after closing via the trigger toggle")
    func popoverReopensAfterTriggerToggle() { GlobalTestLock.locked {
        PortalRegistry.clear()
        defer { PortalRegistry.clear() }

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
        let box = ActionBox()
        graph.install(root: ReopenHarness(box: box))
        graph.computeLayout(width: 240, height: 180)

        let dispatcher = EventDispatcher(tree: tree,
                                         interactions: registry,
                                         capture: capture,
                                         focusChain: focus)
        dispatcher.inputScene = graph.inputScene

        func settle() {
            // Drain like the runtime loop: keep committing while work remains.
            while recomposer.commitAll() {}
            graph.computeLayout(width: 240, height: 180)
        }

        // Open → close (toggle the trigger again) → reopen, all via the trigger.
        click(dispatcher, x: 10, y: 10); settle()
        #expect(PortalRegistry.entries.count == 1)

        click(dispatcher, x: 10, y: 10); settle()
        #expect(PortalRegistry.entries.count == 0)
        #expect(PointerCaptureHolder.current?.target == nil)

        click(dispatcher, x: 10, y: 10); settle()
        #expect(PortalRegistry.entries.count == 1)
        #expect(!menuItemRows(in: tree.root, id: AnyHashable("reopen-item")).isEmpty)
    } }

    @Test("Nested popover refreshes a parent PortalHost when opened")
    func nestedPopoverRefreshesParentPortalHost() { GlobalTestLock.locked {
        PortalRegistry.clear()
        defer { PortalRegistry.clear() }

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
        let box = ActionBox()
        graph.install(root: NestedPortalRootHarness(box: box))
        graph.computeLayout(width: 240, height: 180)

        let dispatcher = EventDispatcher(tree: tree,
                                         interactions: registry,
                                         capture: capture,
                                         focusChain: focus)
        dispatcher.inputScene = graph.inputScene

        click(dispatcher, x: 10, y: 10)
        _ = recomposer.commitAll()
        graph.computeLayout(width: 240, height: 180)

        guard let menuItem = menuItemRows(in: tree.root, id: AnyHashable("nested-new-scene"))
            .first
        else {
            Issue.record("nested menu item row was not materialized")
            return
        }

        click(dispatcher,
              x: Float(menuItem.origin.x + menuItem.node.frame.width * 0.5),
              y: Float(menuItem.origin.y + menuItem.node.frame.height * 0.5))

        #expect(box.fired == 1)
    } }

    private func click(_ dispatcher: EventDispatcher, x: Float, y: Float) {
        let event = MouseButtonEvent(button: .left, x: x, y: y, clicks: 1)
        dispatcher.dispatch(.mouseButtonDown(event))
        dispatcher.dispatch(.mouseButtonUp(event))
    }

    private func menuItemRows(in node: Node?, id: AnyHashable) -> [(node: Node, origin: CGPoint)] {
        var out: [(node: Node, origin: CGPoint)] = []
        collectMenuItemRows(node, id: id, parentOrigin: .zero, into: &out)
        return out
    }

    private func collectMenuItemRows(_ node: Node?,
                                     id: AnyHashable,
                                     parentOrigin: CGPoint,
                                     into out: inout [(node: Node, origin: CGPoint)]) {
        guard let node else { return }
        let origin = CGPoint(x: parentOrigin.x + node.frame.origin.x,
                             y: parentOrigin.y + node.frame.origin.y)
        if node.attachments["__menu_item_id"] as? AnyHashable == id {
            out.append((node, origin))
        }

        let childOrigin = CGPoint(x: origin.x - node.contentOffset.x,
                                  y: origin.y - node.contentOffset.y)
        for child in node.children {
            collectMenuItemRows(child, id: id, parentOrigin: childOrigin, into: &out)
        }
    }

    private func findProbe(id: String, in node: Node?) -> Node? {
        guard let node else { return nil }
        if node.attachments["probeID"] as? String == id {
            return node
        }
        for child in node.children {
            if let match = findProbe(id: id, in: child) {
                return match
            }
        }
        return nil
    }
}
