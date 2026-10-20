import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Sectioned list", .serialized)
struct SectionedListTests: GuavaUIComposeSerializedSuite {
    private struct Item: Identifiable, Equatable {
        let id: Int
        var title: String { "Item \(id)" }
    }

    private func nodes(_ node: Node?) -> [Node] {
        guard let node else { return [] }
        return [node] + node.children.flatMap { nodes($0) }
    }

    private func withScene(_ test: (ViewGraph, InteractionRegistry, FocusChain, PointerCapture) throws -> Void) rethrows {
        try GlobalTestLock.locked {
            let oldRegistry = InteractionRegistryHolder.current
            let oldFocus = FocusChainHolder.current
            let oldCapture = PointerCaptureHolder.current
            let oldText = TextEnvironmentHolder.current
            let registry = InteractionRegistry(), focus = FocusChain(), capture = PointerCapture()
            InteractionRegistryHolder.current = registry
            FocusChainHolder.current = focus
            PointerCaptureHolder.current = capture
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer {
                InteractionRegistryHolder.current = oldRegistry
                FocusChainHolder.current = oldFocus
                PointerCaptureHolder.current = oldCapture
                TextEnvironmentHolder.current = oldText
            }
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            try test(graph, registry, focus, capture)
            graph.install(root: EmptyView())
            AnimatorScheduler.current.tick(deltaTime: 1)
        }
    }

    private func click(_ node: Node, registry: InteractionRegistry,
                       focus: FocusChain, capture: PointerCapture) {
        let frame = node.absoluteFrame
        let event = MouseButtonEvent(button: .left, x: Float(frame.midX), y: Float(frame.midY), clicks: 1)
        let pointer = registry.handlers(for: node).pointer!
        _ = pointer(event, .down, .target)
        _ = pointer(event, .up, .target)
    }

    private func named(_ name: String, in graph: ViewGraph) throws -> Node {
        try #require(nodes(graph.tree.root).first {
            $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == name
        })
    }

    private func stickyNode(in graph: ViewGraph) -> Node? {
        nodes(graph.tree.root).first {
            $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == "sectioned-list-sticky-header"
        }
    }

    private func label(_ text: String, in node: Node) -> Node? {
        nodes(node).first { $0.accessibility?.label == text }
    }

    private func settle(_ graph: ViewGraph) {
        for _ in 0..<4 {
            graph.recomposer.commitAll()
            graph.computeLayout(width: 280, height: 340)
        }
    }

    /// Drives the real ScrollView geometry instead of poking SectionedList's
    /// state, so the test exercises the same report path as a drag or wheel.
    private func scroll(_ graph: ViewGraph, to y: CGFloat) throws {
        let scroll = try #require(nodes(graph.tree.root).first {
            $0.scrollReveal != nil
        })
        scroll.contentOffset = CGPoint(x: 0, y: y)
        scroll.layoutDidUpdate?(scroll)
        settle(graph)
    }

    @Test("Sections render headers/footers and keyboard navigation")
    func sectionsAndKeyboard() {
        withScene { graph, registry, focus, capture in
            var selected: Int? = 1
            var activated: Int?
            let sections = [
                ListSection("a", title: "Alpha", footer: "End of Alpha",
                            items: [Item(id: 1), Item(id: 2)])
            ]
            graph.install(root: SectionedList(sections, selection: Binding(get: { selected }, set: { selected = $0 }),
                                              onActivate: { activated = $0.id }) { item, _ in
                Text(item.title)
            }.frame(width: 240, height: 600))
            graph.computeLayout(width: 280, height: 700)
            let all = nodes(graph.tree.root)
            let hasAlpha = all.contains { $0.accessibility?.label == "Alpha" }
            let hasFooter = all.contains { $0.accessibility?.label == "End of Alpha" }
            #expect(hasAlpha && hasFooter)
            let rows = all.filter { $0.accessibility?.role == .listItem }
            #expect(rows.count == 2)
            guard rows.count == 2 else { return }

            click(rows[0], registry: registry, focus: focus, capture: capture)
            graph.recomposer.commitAll()
            #expect(selected == 1)

            let host = all.first { $0.isFocusable && registry.handlers(for: $0).key != nil }!
            focus.focus(host)
            let key = registry.handlers(for: host).key!
            _ = key(KeyEvent(scancode: Scancode.arrowDown, keycode: 0, modifiers: [], isRepeat: false), .target)
            graph.recomposer.commitAll()
            #expect(selected == 2)
            _ = key(KeyEvent(scancode: Scancode.return, keycode: 0, modifiers: [], isRepeat: false), .target)
            #expect(activated == 2)
        }
    }

    @Test("Sticky headers pin, push, and hand off between sections")
    func stickyHeaders() throws {
        try withScene { graph, registry, focus, capture in
            var selected: Int? = 1
            let sections = [
                ListSection("a", title: "Alpha", items: (1...8).map { Item(id: $0) }),
                ListSection("b", title: "Scene", items: (9...16).map { Item(id: $0) }),
                ListSection("c", title: "Hidden", items: (17...36).map { Item(id: $0) })
            ]
            graph.install(root: SectionedList(
                sections,
                selection: Binding(get: { selected }, set: { selected = $0 }),
                stickyHeaders: true
            ) { item, _ in
                Text(item.title)
            }.frame(width: 240, height: 300).debugName("sectioned-list"))
            settle(graph)

            let list = try named("sectioned-list", in: graph)
            // Nothing is pinned while the first header is still at its own row.
            #expect(stickyNode(in: graph) == nil)

            // The first header detaches from the content and stays at the top.
            try scroll(graph, to: 30)
            let first = try #require(stickyNode(in: graph))
            #expect(abs(first.absoluteFrame.minY - list.absoluteFrame.minY) < 0.5)
            #expect(abs(first.absoluteFrame.minX - list.absoluteFrame.minX) < 0.5)
            #expect(abs(first.frame.width - list.frame.width) < 0.5)
            let band = try named("sectioned-list-sticky-band", in: graph)
            #expect(abs(band.frame.width - (list.frame.width - CGFloat(ScrollView<EmptyView>.scrollbarGutterWidth))) < 0.5)
            #expect(abs(band.absoluteFrame.minX - list.absoluteFrame.minX) < 0.5)
            #expect(label("Alpha", in: first) != nil)
            #expect(nodes(first).contains { $0.accessibility?.isHidden == true })
            #expect(nodes(first).contains { $0.allowsHitTesting == false })

            // At the boundary both copies paint, but only the inline header
            // owns the semantic value.
            try scroll(graph, to: 1)
            func flatten(_ elements: [AccessibilityElement]) -> [AccessibilityElement] {
                elements.flatMap { [$0] + flatten($0.children) }
            }
            let snapshot = AccessibilityTree.snapshot(root: graph.tree.root!)
            #expect(flatten(snapshot).filter { $0.semantics.label == "Alpha" }.count == 1)

            // The next header pushes it up instead of overlapping.
            try scroll(graph, to: 255)
            let pushed = try #require(stickyNode(in: graph))
            #expect(abs(pushed.absoluteFrame.minY - (list.absoluteFrame.minY - 15)) < 0.5)
            #expect(label("Alpha", in: pushed) != nil)

            // Once the second header reaches the top it owns the pinned slot.
            try scroll(graph, to: 280)
            let second = try #require(stickyNode(in: graph))
            #expect(label("Scene", in: second) != nil)
            #expect(abs(second.absoluteFrame.minY - list.absoluteFrame.minY) < 0.5)

            // Programmatic reveal (End) moves the pinned header too.
            try scroll(graph, to: 0)
            let all = nodes(graph.tree.root)
            let host = try #require(all.first { $0.isFocusable && registry.handlers(for: $0).key != nil })
            focus.focus(host)
            let key = try #require(registry.handlers(for: host).key)
            _ = key(KeyEvent(scancode: Scancode.end, keycode: 0, modifiers: [], isRepeat: false), .target)
            settle(graph)
            let last = try #require(stickyNode(in: graph))
            #expect(label("Hidden", in: last) != nil)
        }
    }

    @Test("Sticky headers stay opt-in")
    func stickyHeadersDisabled() throws {
        try withScene { graph, _, _, _ in
            var selected: Int? = 1
            let sections = [
                ListSection("a", title: "Alpha", items: (1...8).map { Item(id: $0) }),
                ListSection("b", title: "Scene", items: (9...16).map { Item(id: $0) })
            ]
            graph.install(root: SectionedList(
                sections,
                selection: Binding(get: { selected }, set: { selected = $0 })
            ) { item, _ in
                Text(item.title)
            }.frame(width: 240, height: 300))
            settle(graph)
            try scroll(graph, to: 255)
            #expect(stickyNode(in: graph) == nil)
            #expect(nodes(graph.tree.root).contains { $0.accessibility?.label == "Scene" })
        }
    }
}
