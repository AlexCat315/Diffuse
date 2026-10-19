import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("List row content", .serialized)
@MainActor
struct ListRowTests: GuavaUIComposeSerializedSuite {
    private enum Kind: CaseIterable { case single, multiple, sections }
    private struct Item: Identifiable { let id: Int }
    nonisolated private static func title(_ index: Int) -> String {
        "Document \(index + 1) — 工作区设置与权限 👨‍👩‍👧‍👦 — a long localized title that must remain readable"
    }
    private final class Harness: View {
        let kind: Kind
        @State var width: Float = 390
        @State var scale: Float = 1
        @State var input: UIEnvironment.Input = [.pointer, .keyboard]
        @State var rtl = false
        @State var dark = false
        @State var count = 18
        @State var selected: Int? = 1
        @State var multiple: Set<Int> = [1]
        @State var actions = 0
        @State var activated: Int?
        @State var hasAction = false
        init(_ kind: Kind) { self.kind = kind }
        var body: some View {
            var surface = UIEnvironment(); surface.viewport.width = width; surface.input = input
            return LayerRoot { collection.frame(width: width, height: 240) }
                .surfaceEnvironment(surface).textScaler(.init(scale)).appearance(dark ? .dark : .light)
                .layoutDirection(rtl ? .rtl : .ltr)
        }
        @ViewBuilder private var collection: some View {
            switch kind {
            case .single:
                List(0..<count, id: \.self, selection: $selected, onActivate: { self.activated = $0 }) { index, _ in self.row(index) }
            case .multiple:
                MultiSelectList(0..<count, id: \.self, selection: $multiple, onActivate: { self.activated = $0 }) { index, _ in self.row(index) }
            case .sections:
                SectionedList([ListSection("a", title: "Favorites", items: (0..<count / 2).map(Item.init)),
                               ListSection("b", title: "Scene", items: (count / 2..<count).map(Item.init))],
                              selection: $selected, stickyHeaders: true, onActivate: { self.activated = $0.id }) { item, _ in self.row(item.id) }
            }
        }
        private func row(_ index: Int) -> some View {
            ListRow(ListRowTests.title(index), leading: {
                Icon(UIIcons.Status.bookmark, size: .medium, color: .accent).accessibilityHidden().debugName("row-icon-\(index)")
            }, trailing: {
                Row(alignment: .center, spacing: 8) {
                    Badge("99", tone: .info)
                    Text("Synced").font(.caption).foregroundColor(.onSurfaceMuted).debugName("row-state-\(index)")
                    if hasAction {
                        Button("Inspect") { self.actions += 1 }.buttonStyle(.ghost).accessibilityLabel("Inspect \(index)")
                    }
                }.debugName("row-trailing-\(index)")
            }).font(.body)
        }
    }
    private func nodes(_ node: Node?) -> [Node] { guard let node else { return [] }; return [node] + node.children.flatMap(nodes) }
    private func elements(_ items: [AccessibilityElement]) -> [AccessibilityElement] { items.flatMap { [$0] + elements($0.children) } }
    private func settle(_ graph: ViewGraph, _ h: Harness) {
        for _ in 0..<8 { graph.recomposer.commitAll(); graph.computeLayout(width: h.width, height: 240) }
    }
    private func named(_ name: String, _ graph: ViewGraph) throws -> Node {
        try #require(nodes(graph.tree.root).first { $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == name })
    }
    private func text(_ value: String, _ graph: ViewGraph) throws -> Node {
        try #require(nodes(graph.tree.root).first { $0.layoutNode?.textInputs?.text == value })
    }
    private func keyboardHost(_ graph: ViewGraph, _ context: PlatformInputContext) -> Node? {
        for node in nodes(graph.tree.root) where node.isFocusable && node.accessibility?.role != .button {
            if context.interactions.handlers(for: node).key != nil { return node }
        }
        return nil
    }
    private func scene(_ kind: Kind, _ work: (Harness, ViewGraph, PlatformInputContext, EventDispatcher) throws -> Void) throws {
        try GlobalTestLock.locked {
            let old = TextEnvironmentHolder.current; TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = old }
            let context = PlatformInputContext(), scheduler = AnimatorScheduler()
            try context.withCurrent { try AnimatorScheduler.$current.withValue(scheduler) {
                let h = Harness(kind), graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                graph.install(root: h); settle(graph, h)
                defer { graph.install(root: EmptyView()); scheduler.reset() }
                let input = EventDispatcher(tree: graph.tree, interactions: context.interactions, capture: context.pointerCapture, focusChain: context.focusChain)
                try work(h, graph, context, input)
            } }
        }
    }
    private func click(_ node: Node, _ input: EventDispatcher) {
        let frame = node.absoluteFrame
        let event = MouseButtonEvent(button: .left, x: Float(frame.midX), y: Float(frame.midY), clicks: 1)
        input.dispatch(.mouseButtonDown(event)); input.dispatch(.mouseButtonUp(event))
    }
    private func key(_ code: UInt32, _ input: EventDispatcher) {
        input.dispatch(.keyDown(.init(scancode: code, keycode: 0, modifiers: [], isRepeat: false)))
    }

    @Test("Titles yield to fixed slots at every width, scale, direction and input mode without replacing retained content")
    func matrix() throws {
        for kind in Kind.allCases { try scene(kind) { h, graph, _, _ in
            let original = try text(Self.title(0), graph)
            for width: Float in [240, 390, 720, 1280] { for scale: Float in [1, 2] {
                for input: UIEnvironment.Input in [[.pointer, .keyboard], [.touch], [.touch, .pointer, .keyboard]] {
                    for dark in [false, true] { for rtl in [false, true] {
                        h.width = width; h.scale = scale; h.input = input; h.dark = dark; h.rtl = rtl; settle(graph, h)
                        let title = try text(Self.title(0), graph), trailing = try named("row-trailing-0", graph), icon = try named("row-icon-0", graph)
                        #expect(title === original && title.clipsToBounds && title.frame.width > 0)
                        #expect(trailing.absoluteFrame.minX >= -0.5 && trailing.absoluteFrame.maxX <= CGFloat(width) + 0.5,
                                "\(kind), width \(width), scale \(scale), RTL \(rtl): title \(title.absoluteFrame), trailing \(trailing.absoluteFrame), icon \(icon.absoluteFrame)")
                        if rtl {
                            #expect(trailing.absoluteFrame.maxX <= title.absoluteFrame.minX + 0.5)
                            #expect(title.absoluteFrame.maxX <= icon.absoluteFrame.minX + 0.5)
                        } else {
                            #expect(icon.absoluteFrame.maxX <= title.absoluteFrame.minX + 0.5)
                            #expect(title.absoluteFrame.maxX <= trailing.absoluteFrame.minX + 0.5)
                        }
                        let cache = try #require(title.layoutNode?.textMeasure as? TextLayoutCacheEntry)
                        #expect(cache.result.lines.count == 1)
                        let root = try #require(graph.tree.root)
                        let rows = elements(AccessibilityTree.snapshot(root: root)).filter { $0.semantics.role == .listItem }
                        #expect(rows.contains { $0.semantics.label.contains(Self.title(0)) && $0.semantics.label.contains("Synced") && $0.semantics.label.contains("99") })
                        #expect(h.selected == 1 && h.multiple == [1] && !graph.recomposer.hasPending)
                    } }
                }
            } }
        } }
    }

    @Test("Embedded actions keep row selection independent; pointer and keyboard activation still share the collection model")
    func actionsAndSelection() throws {
        for kind in Kind.allCases { try scene(kind) { h, graph, context, input in
            h.hasAction = true; settle(graph, h)
            let action = try #require(nodes(graph.tree.root).first { $0.isFocusable && $0.accessibility?.label == "Inspect 0" })
            click(action, input); settle(graph, h)
            #expect(h.actions == 1 && h.selected == 1 && h.multiple == [1])
            click(try text(Self.title(0), graph), input); settle(graph, h)
            if kind == .multiple { #expect(h.multiple == [0]) } else { #expect(h.selected == 0) }
            let host = try #require(keyboardHost(graph, context))
            context.focusChain.focus(host); key(Scancode.end, input); settle(graph, h); key(Scancode.return, input)
            #expect(h.activated == h.count - 1)
        } }
    }

    @Test("Oversized fixed content scrolls horizontally and keeps complete combined semantics")
    func overflow() throws {
        try scene(.single) { h, graph, _, input in
          for rtl in [false, true] {
            h.width = 120; h.scale = 2; h.rtl = rtl; settle(graph, h)
            let scroll = try #require(nodes(graph.tree.root).first { $0.accessibility?.role == .scrollArea && $0.accessibility?.combinesChildren == true })
            let root = try #require(graph.tree.root)
            let row = try #require(elements(AccessibilityTree.snapshot(root: root)).first { $0.semantics.role == .listItem })
            #expect(row.semantics.label.contains(Self.title(0)) && row.semantics.label.contains("Synced"))
            let frame = scroll.absoluteFrame
            input.dispatch(.mouseWheel(.init(x: -60, y: 0, mouseX: Float(frame.midX), mouseY: Float(frame.midY), input: .init(unit: .points))))
            settle(graph, h)
            #expect(scroll.contentOffset.x > 0)
            scroll.accessibilityActions.increment?(); settle(graph, h)
            #expect(scroll.contentOffset.x > 0 && h.selected == 1)
            h.width = 720; settle(graph, h)
            #expect(scroll.accessibility == nil && scroll.contentOffset.x == 0)
          }
        }
    }

    @Test("A row mounted by scrolling has its full title width in the first layout pass")
    func firstFrameWidth() throws {
        try scene(.single) { h, graph, _, _ in
            // End navigation mounts rows that were never laid out; one pass only.
            h.selected = h.count - 1
            graph.recomposer.commitAll(); graph.computeLayout(width: h.width, height: 240)
            let first = try text(Self.title(h.count - 1), graph).frame.width
            settle(graph, h)
            let settled = try text(Self.title(h.count - 1), graph).frame.width
            #expect(settled > 100)
            #expect(abs(first - settled) < 1)
        }
    }

    @Test("A 200K-row collection still mounts only a viewport after end navigation")
    func windowing() throws {
        for kind in [Kind.single, .multiple] { try scene(kind) { h, graph, context, input in
            h.count = 200_000; settle(graph, h)
            let host = try #require(keyboardHost(graph, context))
            context.focusChain.focus(host); key(Scancode.end, input); settle(graph, h)
            let rows = nodes(graph.tree.root).filter { $0.accessibility?.role == .listItem }
            #expect(rows.count < 30)
            #expect(try text(Self.title(199_999), graph).frame.width > 0)
        } }
    }

    @Test("Title-only, leading-only and conditional trailing rows retain nonzero text and stable title identity")
    func emptySlots() throws {
        try GlobalTestLock.locked {
            let old = TextEnvironmentHolder.current; TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = old }
            final class EmptySlots: View {
                @State var selected = false
                var body: some View {
                    Box(direction: .column, alignItems: .stretch, spacing: 4) {
                        ListRow("Title only").frame(height: 44)
                        ListRow("Leading only", leading: { Icon(UIIcons.File.file, size: .medium) }, trailing: { EmptyView() }).frame(height: 44)
                        ListRow("Conditional trailing") {
                            if selected { Badge("Selected", tone: .info) }
                        }.frame(height: 44)
                    }.frame(width: 240)
                }
            }
            let context = PlatformInputContext()
            try context.withCurrent {
                let h = EmptySlots(), graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                graph.install(root: h); defer { graph.install(root: EmptyView()) }
                func layout() { for _ in 0..<8 { graph.recomposer.commitAll(); graph.computeLayout(width: 240, height: 180) } }
                layout()
                let original = try text("Conditional trailing", graph)
                for selected in [true, false, true] {
                    h.selected = selected; layout()
                    for title in ["Title only", "Leading only", "Conditional trailing"] {
                        let node = try text(title, graph)
                        #expect(node.frame.width > 0 && node.frame.height > 0)
                    }
                    #expect(try text("Conditional trailing", graph) === original)
                }
            }
        }
    }
}
