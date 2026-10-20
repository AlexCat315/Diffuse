import Foundation
import Testing
import GuavaUIRuntime
import GuavaUIAgent
import GuavaUIDevToolsProtocol
@testable import GuavaUICompose

@Suite("Adaptive grid columns", .serialized)
@MainActor
struct GridColumnsTests: GuavaUIComposeSerializedSuite {
    private struct Counter: View {
        let title: String
        @State private var count = 0
        var body: some View {
            Button("\(title) \(count)") { count += 1 }.accessibilityLabel("\(title) \(count)")
        }
    }
    private struct Draft: View {
        @State private var text: TextBuffer = "Original note"
        var body: some View { TextField("Notes draft", text: $text).accessibilityLabel("Notes draft") }
    }
    private struct CellPopup: View {
        @State private var open = false
        var body: some View {
            Popover(isPresented: $open, surface: .content, overflow: .flip) { Text("Cell popup").padding(8) } content: {
                Menu([.item(MenuItem(id: "action", title: "Cell action") {})], onItemActivated: { open = false })
            }.frame(width: 140, height: 44).compositionLocal(ActionControlAccessibility.label, "Cell popup")
        }
    }
    private final class Harness: View {
        let controlled: Bool
        let popup: Bool
        @State var width: Float = 720
        @State var scale: Float = 1
        @State var input: UIEnvironment.Input = [.pointer, .keyboard]
        @State var dark = false
        @State var rtl = false
        @State var enabled = true
        @State var empty = false
        @State var overrides: [String: Bool] = [:]
        init(controlled: Bool = true, popup: Bool = false, initialWidth: Float? = nil) {
            self.controlled = controlled; self.popup = popup
            if let initialWidth { width = initialWidth }
        }
        var body: some View {
            var surface = UIEnvironment(); surface.input = input; surface.viewport.width = 1280
            return LayerRoot {
                Box(direction: .column, alignItems: .stretch, spacing: 8) {
                    Grid(columns: empty ? [] : [
                        .named(id: "name", title: "Name", sizing: .fixed(140)),
                        .named(id: "notes", title: "Notes", sizing: .flexible(minimum: 160), visibility: .automatic()),
                        .named(id: "quantity", title: "Quantity", sizing: .fixed(100), visibility: .automatic(priority: 10))
                    ], columnSpacing: 10, rowSpacing: 8, columnVisibility: controlled ? $overrides : nil, isEnabled: enabled) {
                        Button("Open one") {}.accessibilityLabel("Open one")
                        if popup { CellPopup() } else { Draft() }
                        Counter(title: "Quantity one")
                        Button("Open two") {}.accessibilityLabel("Open two")
                        Counter(title: "Notes two")
                        Text("Quantity two").accessibilityLabel("Quantity two")
                    }.debugName("grid-fixture")
                    Button("After grid") {}.accessibilityLabel("After grid")
                }.flex(1, shrink: 1, basis: 0)
            }.frame(width: width, height: 400).textScaler(.init(scale)).surfaceEnvironment(surface)
                .appearance(dark ? .dark : .light).layoutDirection(rtl ? .rtl : .ltr).reducedMotion()
        }
    }
    private func nodes(_ root: Node?) -> [Node] {
        var pending = root.map { [$0] } ?? [], result: [Node] = []
        while let node = pending.popLast() { result.append(node); pending.append(contentsOf: node.children.reversed()) }
        return result
    }
    private func target(_ label: String, _ graph: ViewGraph) throws -> Node {
        try #require(nodes(graph.tree.root).first { $0.isFocusable && $0.accessibility?.label == label })
    }
    private func settle(_ graph: ViewGraph, _ h: Harness) {
        for _ in 0..<8 { graph.recomposer.commitAll(); graph.computeLayout(width: h.width, height: 400) }
    }
    private func scene(controlled: Bool = true, popup: Bool = false, initialWidth: Float? = nil,
                       _ work: (Harness, ViewGraph, PlatformInputContext, EventDispatcher, PortalStore) throws -> Void) rethrows {
        try GlobalTestLock.locked {
            let previous = TextEnvironmentHolder.current; TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = previous }
            let context = PlatformInputContext(), portals = PortalStore(), scheduler = AnimatorScheduler()
            context.addScopedAmbient(PortalStoreAmbient(portals))
            try context.withCurrent { try AnimatorScheduler.$current.withValue(scheduler) {
                let h = Harness(controlled: controlled, popup: popup, initialWidth: initialWidth), graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                let input = EventDispatcher(tree: graph.tree, interactions: context.interactions,
                    capture: context.pointerCapture, focusChain: context.focusChain)
                graph.install(root: h); settle(graph, h)
                defer { graph.install(root: EmptyView()); scheduler.reset() }
                try work(h, graph, context, input, portals)
            } }
        }
    }
    private func click(_ node: Node, _ input: EventDispatcher) {
        let f = node.absoluteFrame
        let e = MouseButtonEvent(button: .left, x: Float(f.midX), y: Float(f.midY), clicks: 1)
        input.dispatch(.mouseButtonDown(e)); input.dispatch(.mouseButtonUp(e))
    }
    private func key(_ code: UInt32, _ input: EventDispatcher, modifiers: KeyModifiers = []) {
        input.dispatch(.keyDown(.init(scancode: code, keycode: 0, modifiers: modifiers, isRepeat: false)))
    }

    @Test("Column hiding preserves each source row across allocation, scale, modality, theme and RTL")
    func matrix() throws {
        try scene { h, graph, _, _, _ in
            let one = try target("Open one", graph), two = try target("Open two", graph)
            let quantity = try target("Quantity one 0", graph), notes = try target("Notes draft", graph)
            for width: Float in [390, 720, 1280] { for scale: Float in [1, 2] {
                for input: UIEnvironment.Input in [[.touch], [.touch, .pointer, .keyboard], [.pointer, .keyboard]] {
                    for dark in [false, true] { for rtl in [false, true] {
                        h.width = width; h.scale = scale; h.input = input; h.dark = dark; h.rtl = rtl; settle(graph, h)
                        #expect(try target("Open one", graph) === one)
                        #expect(try target("Open two", graph) === two)
                        #expect(try target("Quantity one 0", graph) === quantity)
                        #expect(notes.acceptsSubtreeInput == (width != 390))
                        #expect(quantity.acceptsSubtreeInput && one.acceptsSubtreeInput)
                        #expect(quantity.absoluteFrame.minY == one.absoluteFrame.minY)
                        #expect(two.absoluteFrame.minY > one.absoluteFrame.minY)
                        #expect(rtl ? quantity.absoluteFrame.minX < one.absoluteFrame.minX : quantity.absoluteFrame.minX > one.absoluteFrame.minX)
                        let picker = try target("Column visibility", graph)
                        #expect(picker.frame.width >= 44 && picker.frame.height >= 44)
                        if input.contains(.touch) { #expect(one.frame.width >= 44 && one.frame.height >= 44) }
                        #expect(!graph.recomposer.hasPending)
                    } }
                }
            } }
        }
    }

    @Test("Hidden cells retain drafts and local state, release capture/focus and disappear from accessibility")
    func retainedCells() throws {
        try scene { h, graph, context, input, _ in
            let notes = try target("Notes draft", graph)
            context.focusChain.focus(notes)
            key(Scancode.a, input, modifiers: .gui); input.dispatch(.textInput("Keep this draft")); settle(graph, h)
            let counter = try target("Quantity one 0", graph)
            click(counter, input); settle(graph, h)
            #expect(try target("Quantity one 1", graph) === counter)
            context.focusChain.focus(counter)
            context.pointerCapture.acquire(counter)
            h.width = 180; settle(graph, h)
            #expect(context.focusChain.focused == nil && context.pointerCapture.target == nil)
            #expect(!counter.acceptsSubtreeInput && !notes.acceptsSubtreeInput)
            func labels(_ elements: [AccessibilityElement]) -> [String] {
                elements.flatMap { [$0.semantics.label] + labels($0.children) }
            }
            let visibleLabels = labels(AccessibilityTree.snapshot(root: graph.tree.root!))
            #expect(!visibleLabels.contains("Notes draft") && !visibleLabels.contains("Quantity one 1"))
            h.width = 720; settle(graph, h)
            #expect(try target("Quantity one 1", graph) === counter)
            #expect(try target("Notes draft", graph) === notes)
            #expect(notes.resolvedAccessibilityValue == "Keep this draft")
            h.empty = true; settle(graph, h)
            #expect(!oneIsVisible("Open one", graph))
            h.empty = false; settle(graph, h)
            #expect(try target("Quantity one 1", graph) === counter)
        }
    }
    private func oneIsVisible(_ label: String, _ graph: ViewGraph) -> Bool {
        nodes(graph.tree.root).contains { $0.accessibility?.label == label && $0.acceptsSubtreeInput }
    }

    @Test("Visibility menu restores hidden fields, resets choices, and disabled grids release interactions")
    func menu() throws {
        try scene { h, graph, context, input, portals in
            h.width = 390; settle(graph, h)
            let picker = try target("Column visibility", graph)
            click(picker, input); settle(graph, h)
            let name = try #require(nodes(graph.tree.root).first { $0.accessibility?.label == "Name" && $0.accessibility?.role == .button })
            #expect(name.accessibility?.state.isEnabled == false && name.accessibility?.state.isSelected == true)
            let notes = try target("Notes", graph)
            #expect(notes.frame.height >= 44)
            click(notes, input); settle(graph, h)
            #expect(h.overrides["notes"] == true && oneIsVisible("Notes draft", graph))
            #expect(context.focusChain.focused === picker)
            click(picker, input); settle(graph, h)
            click(try target("Automatic columns", graph), input); settle(graph, h)
            #expect(h.overrides.isEmpty && !oneIsVisible("Notes draft", graph))
            click(picker, input); settle(graph, h)
            h.enabled = false; settle(graph, h)
            #expect(portals.entries.isEmpty && context.pointerCapture.target == nil && context.focusChain.focused == nil)
            #expect(!oneIsVisible("Open one", graph))
        }
    }

    @Test("User-forced columns and an oversized required minimum remain horizontally reachable")
    func scrolling() throws {
        try scene { h, graph, context, input, _ in
            h.width = 390; h.overrides = ["notes": true, "quantity": true]; settle(graph, h)
            let last = try target("Quantity one 0", graph)
            context.focusChain.focus(last); ScrollReveal.reveal(last); settle(graph, h)
            let q = try UIDiagnostics(tree: graph.tree).queryNodes(text: "Quantity one 0", role: "button", visibleOnly: true)
            #expect(q.total == 1 && (q.items.first?.presentation.visibleFrame?.w ?? 0) > 0)
            let scroller = try #require(nodes(graph.tree.root).first { $0.scrollReveal != nil && $0.clipsToBounds })
            #expect(scroller.contentOffset.x > 0)
            h.overrides = [:]; h.width = 100; settle(graph, h)
            #expect(try target("Open one", graph).frame.width >= 44)
            input.dispatch(.mouseWheel(.init(x: -10, y: 0, mouseX: Float(scroller.absoluteFrame.midX), mouseY: Float(scroller.absoluteFrame.midY))))
            settle(graph, h)
            #expect(scroller.contentOffset.x > 0 && scroller.contentOffset.x <= 40)
        }
    }

    @Test("Validated AI reads exclude hidden retained controls and reflect restored choices")
    func aiQueries() throws {
        try scene { h, graph, _, _, _ in
            h.width = 390; settle(graph, h)
            let diagnostic = UIDiagnostics(tree: graph.tree)
            @MainActor func count() throws -> Int {
                let response = diagnostic.handleReadRequest(DevToolsEnvelope(type: "diagnostics.call", id: 1, payload: .object([
                    "name": .string("query_ui_nodes"), "arguments": .object([
                        "text": .string("Notes draft"), "role": .string("textField"), "visible_only": .bool(true), "input_enabled_only": .bool(true)
                    ])
                ])))
                #expect(response.type == "diagnostics.call.ok")
                let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(response.payload)) as? [String: Any])
                return try #require((json["data"] as? [String: Any])?["total"] as? Int)
            }
            let hidden = try count(); #expect(hidden == 0)
            h.overrides["notes"] = true; settle(graph, h)
            let shown = try count(); #expect(shown == 1)
            h.enabled = false; settle(graph, h)
            let disabled = try count(); #expect(disabled == 0)
        }
    }

    @Test("Local visibility choices reset after the grid unmounts")
    func localSession() throws {
        try scene(controlled: false) { h, graph, _, input, _ in
            h.width = 390; settle(graph, h)
            click(try target("Column visibility", graph), input); settle(graph, h)
            click(try target("Notes", graph), input); settle(graph, h)
            #expect(oneIsVisible("Notes draft", graph))
            graph.install(root: EmptyView()); graph.install(root: h); settle(graph, h)
            #expect(!oneIsVisible("Notes draft", graph))
        }
    }

    @Test("Hiding a cell closes its owned popup and a restored trigger opens on the first click")
    func ownedPopup() throws {
        try scene(popup: true) { h, graph, _, input, portals in
            click(try target("Cell popup", graph), input); settle(graph, h)
            #expect(!portals.entries.isEmpty)
            h.width = 180; settle(graph, h)
            #expect(portals.entries.isEmpty)
            let hidden = try UIDiagnostics(tree: graph.tree).queryNodes(text: "Cell action", role: "button", inputEnabledOnly: true)
            #expect(hidden.total == 0)
            h.width = 720; settle(graph, h)
            #expect(portals.entries.isEmpty)
            click(try target("Cell popup", graph), input); settle(graph, h)
            #expect(!portals.entries.isEmpty)
        }
    }

    @Test("Cells hidden on their first layout expose finite zero geometry and recover their original content")
    func initiallyHidden() throws {
        try scene(initialWidth: 390) { h, graph, _, _, _ in
            let draft = try target("Notes draft", graph)
            for node in nodes(graph.tree.root) {
                #expect(node.frame.origin.x.isFinite && node.frame.origin.y.isFinite)
                #expect(node.frame.size.width.isFinite && node.frame.size.height.isFinite)
            }
            #expect(!draft.acceptsSubtreeInput)
            h.width = 720; settle(graph, h)
            #expect(try target("Notes draft", graph) === draft)
            #expect(draft.frame.width > 0 && draft.resolvedAccessibilityValue == "Original note")
        }
    }
}
