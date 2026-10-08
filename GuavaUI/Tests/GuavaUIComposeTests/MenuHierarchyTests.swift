import Foundation
import Testing
import EngineKernel
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Menu hierarchy", .serialized)
@MainActor
struct MenuHierarchyTests: GuavaUIComposeSerializedSuite {
    private final class Probe { var actions = 0 }
    private struct Harness: View {
        @State var entries: [MenuEntry]
        @State var shown = false
        var nearEdge = false
        var body: some View {
            LayerRoot {
                Popover(isPresented: $shown, width: 180) { Text("Open") } content: {
                    Menu(entries, width: 180, maxVisibleRows: 4, onItemActivated: { shown = false })
                }
                .absolutePosition(left: nearEdge ? 450 : 0, top: nearEdge ? 310 : 0)
            }
        }
    }
    private func nodes(_ node: Node?) -> [Node] {
        guard let node else { return [] }; return [node] + node.children.flatMap { nodes($0) }
    }
    private func scene(_ work: (ViewGraph, PlatformInputContext, PortalStore, AnimatorScheduler, EventDispatcher) throws -> Void) rethrows {
        try GlobalTestLock.locked {
            let prior = TextEnvironmentHolder.current; TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = prior }
            let context = PlatformInputContext(), portal = PortalStore(), scheduler = AnimatorScheduler()
            context.addScopedAmbient(PortalStoreAmbient(portal))
            try context.withCurrent { try AnimatorScheduler.$current.withValue(scheduler) {
                let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                let dispatcher = EventDispatcher(tree: graph.tree, interactions: context.interactions,
                    capture: context.pointerCapture, focusChain: context.focusChain)
                defer { graph.install(root: EmptyView()); scheduler.tick(deltaTime: 1); graph.recomposer.commitAll() }
                try work(graph, context, portal, scheduler, dispatcher)
            } }
        }
    }
    private func settle(_ graph: ViewGraph) {
        for _ in 0..<6 { graph.recomposer.commitAll(); graph.computeLayout(width: 640, height: 400) }
    }
    private func key(_ code: UInt32, graph: ViewGraph, dispatcher: EventDispatcher) {
        dispatcher.dispatch(.keyDown(KeyEvent(scancode: code, keycode: 0, modifiers: [], isRepeat: false)))
        settle(graph)
    }
    private func row(_ id: String, graph: ViewGraph) throws -> Node {
        try #require(nodes(graph.tree.root).first { $0.attachments["__menu_item_id"] as? AnyHashable == AnyHashable(id) })
    }

    @Test("Three-level keyboard menus skip decoration and disabled entries, restore each branch and activate once")
    func nestedKeyboard() throws { try scene { graph, context, portal, scheduler, dispatcher in
        let probe = Probe()
        let entries: [MenuEntry] = [
            .label(id: "label", title: "Workspace"), .separator("sep"),
            .item(MenuItem(id: "disabled", title: "Disabled", isEnabled: false) { probe.actions += 100 }),
            .submenu(MenuSubmenu(id: "branch", title: "Settings", entries: [
                .submenu(MenuSubmenu(id: "nested", title: "Appearance", entries: [
                    .item(MenuItem(id: "leaf", title: "Dark theme") { probe.actions += 1 })
                ]))
            ])),
            .item(MenuItem(id: "last", title: "Last") { probe.actions += 10 })
        ]
        let harness = Harness(entries: entries); graph.install(root: harness); settle(graph)
        let trigger = try #require(nodes(graph.tree.root).first { $0.attachments[ButtonHost.markerKey] != nil })
        context.focusChain.focus(trigger); harness.$shown.wrappedValue = true; settle(graph)
        scheduler.tick(deltaTime: 1); settle(graph)
        #expect(context.focusChain.focused === (try row("branch", graph: graph)))
        key(Scancode.arrowDown, graph: graph, dispatcher: dispatcher)
        #expect(context.focusChain.focused === (try row("last", graph: graph)))
        key(Scancode.arrowUp, graph: graph, dispatcher: dispatcher)
        key(Scancode.arrowRight, graph: graph, dispatcher: dispatcher)
        #expect(portal.entries.count == 2)
        #expect(context.focusChain.focused === (try row("nested", graph: graph)))
        key(Scancode.arrowRight, graph: graph, dispatcher: dispatcher)
        #expect(portal.entries.count == 3)
        #expect(context.focusChain.focused === (try row("leaf", graph: graph)))
        key(Scancode.escape, graph: graph, dispatcher: dispatcher)
        #expect(harness.shown && portal.entries.count == 2)
        #expect(context.focusChain.focused === (try row("nested", graph: graph)))
        key(Scancode.arrowLeft, graph: graph, dispatcher: dispatcher)
        #expect(portal.entries.count == 1 && harness.shown)
        #expect(context.focusChain.focused === (try row("branch", graph: graph)))
        key(Scancode.arrowRight, graph: graph, dispatcher: dispatcher)
        key(Scancode.arrowRight, graph: graph, dispatcher: dispatcher)
        key(Scancode.return, graph: graph, dispatcher: dispatcher)
        #expect(probe.actions == 1 && !harness.shown && portal.entries.isEmpty)
        scheduler.tick(deltaTime: 1); settle(graph)
        #expect(context.focusChain.focused === trigger)
        #expect(context.focusChain.activeScopeRoot == nil)
    } }

    @Test("Home, End and typeahead reveal offscreen items using their actual geometry")
    func scrollNavigation() throws { try scene { graph, context, _, scheduler, dispatcher in
        let harness = Harness(entries: (0..<100).map { .item(MenuItem(id: "item-\($0)", title: "Command \($0)") {}) })
        graph.install(root: harness); settle(graph); harness.$shown.wrappedValue = true; settle(graph)
        scheduler.tick(deltaTime: 1); settle(graph)
        key(Scancode.end, graph: graph, dispatcher: dispatcher)
        let last = try row("item-99", graph: graph)
        #expect(context.focusChain.focused === last)
        let scroll = try #require(nodes(graph.tree.root).first { $0.attachments[MenuScrollMarker.key] as? Bool == true })
        #expect(scroll.contentOffset.y > 3000)
        #expect(last.absoluteFrame.minY >= scroll.absoluteFrame.minY - 1)
        #expect(last.absoluteFrame.maxY <= scroll.absoluteFrame.maxY + 1)
        key(Scancode.home, graph: graph, dispatcher: dispatcher)
        #expect(context.focusChain.focused === (try row("item-0", graph: graph)))
        #expect(scroll.contentOffset.y == 0)
        dispatcher.dispatch(.textInput("Command 8")); settle(graph)
        let found = try row("item-8", graph: graph)
        #expect(context.focusChain.focused === found)
        #expect(found.absoluteFrame.maxY <= scroll.absoluteFrame.maxY + 1)
    } }

    @Test("Submenus flip horizontally, stay within the viewport, and never flip above their parent row")
    func horizontalPlacement() {
        let window = CGRect(x: 0, y: 0, width: 640, height: 400)
        let anchor = CGRect(x: 450, y: 350, width: 180, height: 32)
        let placed = PortalPlacement.fit(position: CGPoint(x: anchor.maxX, y: anchor.minY),
            size: CGSize(width: 200, height: 160), in: window, anchor: anchor, placement: .besideAnchor)
        #expect(placed.minX == 250 && placed.minY == 234)
        #expect(window.contains(placed))
    }

    @Test("Hover intent cancels on departure; child clicks, outside dismissal and disable leave no portals")
    func hoverLifecycle() throws { try scene { graph, context, portal, scheduler, dispatcher in
        let probe = Probe()
        let branch = MenuSubmenu(id: "branch", title: "Tools", entries: [
            .item(MenuItem(id: "leaf", title: "Build") { probe.actions += 1 })
        ])
        let harness = Harness(entries: [.submenu(branch), .item(MenuItem(id: "sibling", title: "Copy") {})])
        graph.install(root: harness); settle(graph); harness.$shown.wrappedValue = true; settle(graph)
        scheduler.tick(deltaTime: 1); settle(graph)
        let target = try row("branch", graph: graph)
        let hover = try #require(context.interactions.handlers(for: target).hover)
        hover(.enter); scheduler.tick(deltaTime: 0.1); hover(.leave)
        scheduler.tick(deltaTime: 0.2); settle(graph); #expect(portal.entries.count == 1)
        hover(.enter); scheduler.tick(deltaTime: 0.2); settle(graph)
        #expect(portal.entries.count == 2 && target.accessibility?.state.isExpanded == true)
        let leaf = try row("leaf", graph: graph)
        let event = MouseButtonEvent(button: .left, x: Float(leaf.absoluteFrame.midX), y: Float(leaf.absoluteFrame.midY), clicks: 1)
        dispatcher.dispatch(.mouseButtonDown(event)); dispatcher.dispatch(.mouseButtonUp(event)); settle(graph)
        #expect(probe.actions == 1 && !harness.shown && portal.entries.isEmpty)
        scheduler.tick(deltaTime: 1); settle(graph)
        harness.$shown.wrappedValue = true; settle(graph); scheduler.tick(deltaTime: 1); settle(graph)
        key(Scancode.arrowRight, graph: graph, dispatcher: dispatcher)
        #expect(portal.entries.count == 2)
        var disabled = branch; disabled.isEnabled = false
        harness.$entries.wrappedValue = [.submenu(disabled)]; settle(graph)
        let disabledRow = try row("branch", graph: graph)
        #expect(portal.entries.count == 1 && !disabledRow.isFocusable)
        portal.dismissOutside(CGPoint(x: 600, y: 390)); settle(graph)
        #expect(!harness.shown && portal.entries.isEmpty)
        scheduler.tick(deltaTime: 1); settle(graph)
        #expect(context.focusChain.activeScopeRoot == nil)
    } }

    @Test("Select opens at its selected row, skips disabled options and restores the trigger")
    func selectNavigation() throws { try scene { graph, context, portal, scheduler, dispatcher in
        var selected = 2
        graph.install(root: LayerRoot {
            Select(selection: Binding(get: { selected }, set: { selected = $0 }), options: [
                SelectOption(value: 1, label: "First"), SelectOption(value: 2, label: "Current"),
                SelectOption(value: 3, label: "Disabled", isEnabled: false), SelectOption(value: 4, label: "Last")
            ], width: 180)
        }); settle(graph)
        let trigger = try #require(nodes(graph.tree.root).first { $0.attachments[ButtonHost.markerKey] != nil })
        context.focusChain.focus(trigger)
        key(Scancode.return, graph: graph, dispatcher: dispatcher); scheduler.tick(deltaTime: 1); settle(graph)
        #expect(context.focusChain.focused?.attachments["__menu_item_id"] as? AnyHashable == AnyHashable(2))
        key(Scancode.arrowDown, graph: graph, dispatcher: dispatcher)
        #expect(context.focusChain.focused?.attachments["__menu_item_id"] as? AnyHashable == AnyHashable(4))
        key(Scancode.return, graph: graph, dispatcher: dispatcher)
        #expect(selected == 4 && portal.entries.isEmpty)
        scheduler.tick(deltaTime: 1); settle(graph)
        #expect(context.focusChain.focused === trigger)
    } }

    @Test("Typeahead folds accents, cycles repeated letters and resets after inactivity")
    func typeaheadPolicy() {
        var search = MenuTypeahead()
        let rows = [MenuRowPresentation(item: MenuItem(id: "a", title: "Éclair") {}),
                    MenuRowPresentation(item: MenuItem(id: "b", title: "Echo") {}),
                    MenuRowPresentation(item: MenuItem(id: "c", title: "Tools") {})]
        #expect(search.destination("e", rows: rows, from: nil, time: 1) == AnyHashable("a"))
        #expect(search.destination("e", rows: rows, from: "a", time: 1.2) == AnyHashable("b"))
        #expect(search.destination("t", rows: rows, from: "b", time: 3) == AnyHashable("c"))
    }

    @Test("Four portal levels flip at the window edge and are removed with their owning popup")
    func edgeHierarchy() throws { try scene { graph, context, portal, scheduler, dispatcher in
        let entries: [MenuEntry] = [.submenu(MenuSubmenu(id: "a", title: "First", entries: [
            .submenu(MenuSubmenu(id: "b", title: "Second", entries: [
                .submenu(MenuSubmenu(id: "c", title: "Third", entries: [
                    .item(MenuItem(id: "d", title: "Deep command") {})
                ]))
            ]))
        ]))]
        let harness = Harness(entries: entries, nearEdge: true)
        graph.install(root: harness); settle(graph); harness.$shown.wrappedValue = true; settle(graph)
        scheduler.tick(deltaTime: 1); settle(graph)
        for _ in 0..<3 { key(Scancode.arrowRight, graph: graph, dispatcher: dispatcher) }
        #expect(portal.entries.count == 4)
        let slots = nodes(graph.tree.root).filter { $0.attachments[PortalOwnership.entryKey] != nil }
        #expect(slots.count == 4)
        let viewport = CGRect(x: 0, y: 0, width: 640, height: 400).insetBy(dx: 5, dy: 5)
        for slot in slots { #expect(viewport.contains(slot.absoluteFrame)) }
        #expect(slots[1].absoluteFrame.minX < slots[0].absoluteFrame.minX)
        let rootID = try #require(portal.entries.first?.id)
        portal.unregister(rootID); settle(graph)
        #expect(portal.entries.isEmpty && context.focusChain.activeScopeRoot == nil)
    } }

    @Test("Scrolling a branch fully outside its clipping viewport closes the child")
    func scrolledAnchor() throws { try scene { graph, _, portal, scheduler, dispatcher in
        let branch = MenuSubmenu(id: "branch", title: "Group", entries: [.item(MenuItem(id: "leaf", title: "Leaf") {})])
        let harness = Harness(entries: [.submenu(branch)] + (0..<40).map { .item(MenuItem(id: $0, title: "Item \($0)") {}) })
        graph.install(root: harness); settle(graph); harness.$shown.wrappedValue = true; settle(graph)
        scheduler.tick(deltaTime: 1); settle(graph)
        key(Scancode.arrowRight, graph: graph, dispatcher: dispatcher)
        #expect(portal.entries.count == 2)
        let scroll = try #require(nodes(graph.tree.root).first { $0.attachments[MenuScrollMarker.key] as? Bool == true })
        dispatcher.dispatch(.mouseWheel(MouseWheelEvent(x: 0, y: -8, mouseX: Float(scroll.absoluteFrame.midX), mouseY: Float(scroll.absoluteFrame.midY))))
        settle(graph)
        #expect(scroll.contentOffset.y >= 200 && portal.entries.count == 1)
    } }

    @Test("Rows preserve text insets, clip long labels and keep separators thin")
    func rowGeometry() throws { try scene { graph, _, _, _, _ in
        let label = String(repeating: "Long command ", count: 30)
        graph.install(root: Menu([.item(MenuItem(id: "long", title: label, shortcut: "⌘K") {}),
                                 .separator("sep"), .item(MenuItem(id: "short", title: "Short") {})], width: 220))
        settle(graph)
        let target = try row("long", graph: graph)
        let title = try #require(nodes(target).first { $0.accessibility?.label == label && $0.accessibility?.role == .staticText })
        #expect(title.clipsToBounds)
        #expect(title.absoluteFrame.minX - target.absoluteFrame.minX == 16)
        let lines = nodes(graph.tree.root).filter { $0.backgroundColor == $0.theme.colors.divider && $0.frame.height > 0 }
        #expect(lines.count == 1 && lines[0].frame.height == 1)
    } }
}
