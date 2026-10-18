import Foundation
import Testing
import GuavaUIRuntime
import GuavaUIAgent
import GuavaUIDevToolsProtocol
@testable import GuavaUICompose

@Suite("Adaptive selection fields", .serialized)
@MainActor
struct SelectionFieldTests: GuavaUIComposeSerializedSuite {
    private nonisolated static let title = "Workspace permissions 👩🏽‍💻 and international collaboration settings"
    private nonisolated static let placeholder = "Choose a workspace with international collaboration permissions"
    private enum Kind: CaseIterable { case select, combobox }
    private final class Harness: View {
        let kind: Kind
        @State var width: Float = 390
        @State var fieldWidth: Float = 240
        @State var preferredWidth: Float?
        @State var scale: Float = 1
        @State var input: UIEnvironment.Input = [.pointer, .keyboard]
        @State var dark = false
        @State var rtl = false
        @State var enabled = true
        @State var selection: Int? = 1
        init(_ kind: Kind) { self.kind = kind }
        var body: some View {
            var surface = UIEnvironment(); surface.viewport.width = width; surface.viewport.height = 600; surface.input = input
            let options = [SelectOption(value: 0, label: "Alpha"), .init(value: 1, label: SelectionFieldTests.title),
                           .init(value: 2, label: "Unavailable", isEnabled: false)]
                + (3..<12).map { SelectOption(value: $0, label: "Option \($0)") }
            return LayerRoot {
                Box(direction: .column, alignItems: .flexStart, spacing: 12) {
                    if kind == .select {
                        Select(selection: Binding(get: { self.selection ?? -1 }, set: { self.selection = $0 }),
                               options: options, isEnabled: enabled, width: preferredWidth,
                               maxVisibleRows: 3, placeholder: SelectionFieldTests.placeholder).frame(width: fieldWidth)
                    } else {
                        Combobox(selection: $selection, options: options) {
                            $0.placeholder = SelectionFieldTests.placeholder; $0.isEnabled = enabled
                            $0.maxVisibleRows = 3
                            if let preferredWidth { $0.width = preferredWidth }
                        }.frame(width: fieldWidth)
                    }
                    Button("After selector") {}.accessibilityLabel("After selector")
                }.padding(12).flex(1, shrink: 1, basis: 0)
            }.frame(width: width, height: 600).surfaceEnvironment(surface).textScaler(.init(scale))
                .appearance(dark ? .dark : .light).layoutDirection(rtl ? .rtl : .ltr).reducedMotion()
        }
    }
    private func nodes(_ root: Node?) -> [Node] {
        var pending = root.map { [$0] } ?? [], result: [Node] = []
        while let node = pending.popLast() { result.append(node); pending.append(contentsOf: node.children.reversed()) }
        return result
    }
    private func target(_ label: String, in graph: ViewGraph) throws -> Node {
        try #require(nodes(graph.tree.root).first { $0.isHitTestable && $0.accessibility?.label == label })
    }
    private func settle(_ graph: ViewGraph, _ h: Harness) {
        for _ in 0..<10 { graph.recomposer.commitAll(); graph.computeLayout(width: h.width, height: 600) }
    }
    private func scene(_ kind: Kind,
                       _ work: (Harness, ViewGraph, PlatformInputContext, EventDispatcher, PortalStore) throws -> Void) rethrows {
        try GlobalTestLock.locked {
            let old = TextEnvironmentHolder.current; TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = old }
            let context = PlatformInputContext(), portals = PortalStore(), scheduler = AnimatorScheduler()
            context.addScopedAmbient(PortalStoreAmbient(portals))
            try context.withCurrent { try AnimatorScheduler.$current.withValue(scheduler) {
                let h = Harness(kind), graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
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
    private func key(_ code: UInt32, _ input: EventDispatcher) {
        input.dispatch(.keyDown(.init(scancode: code, keycode: 0, modifiers: [], isRepeat: false)))
    }

    @Test("Trigger labels stay single line with complete semantics across width, scale, input, theme and direction")
    func matrix() throws {
        for kind in Kind.allCases { try scene(kind) { h, graph, _, _, _ in
            let original = try target(Self.title, in: graph)
            for width: Float in [390, 720, 1280] { for scale: Float in [1, 2] {
                for modality: UIEnvironment.Input in [[.touch], [.touch, .pointer, .keyboard], [.pointer, .keyboard]] {
                    for dark in [false, true] { for rtl in [false, true] {
                        h.width = width; h.scale = scale; h.input = modality; h.dark = dark; h.rtl = rtl; settle(graph, h)
                        let trigger = try target(Self.title, in: graph)
                        #expect(trigger === original && trigger.accessibility?.value == Self.title && trigger.accessibility?.help == Self.title)
                        #expect(trigger.frame.width <= CGFloat(h.fieldWidth + 1) && trigger.frame.height < 80)
                        if modality.contains(.touch) { #expect(trigger.frame.width >= 44 && trigger.frame.height >= 44) }
                        let text = try #require(nodes(trigger).first { $0.layoutNode?.textInputs?.text == Self.title })
                        let list = DrawList(); NodeRenderer().render(root: try #require(graph.tree.root), into: list)
                        #expect(text.layoutNode?.textInputs?.lineLimit == 1)
                        #expect((text.layoutNode?.textMeasure?.result.lines.count ?? 0) <= 1)
                        #expect((text.layoutNode?.textMeasure?.result.totalWidth ?? .infinity) <= Float(text.frame.width) + 1)
                        #expect(!graph.recomposer.hasPending)
                    } }
                }
            } }
        } }
    }

    @Test("Popups honor the trigger minimum, clamp preferred widths and follow open resizes without replacing the trigger")
    func popupWidths() throws {
        for kind in Kind.allCases { try scene(kind) { h, graph, _, input, portals in
            let trigger = try target(Self.title, in: graph)
            click(trigger, input); settle(graph, h)
            let id = try #require(portals.entries.first?.id)
            for width: Float in [390, 720, 1280, 390] {
                for preferred: Float? in [80, 1200, nil] {
                    h.width = width; h.preferredWidth = preferred; h.fieldWidth = min(500, width - 24); settle(graph, h)
                    let frame = try #require(portals.frame(id))
                    #expect(frame.width >= CGFloat(min(h.fieldWidth, h.width - 24)) - 1)
                    #expect(frame.width <= CGFloat(h.width - 24) + 1 && frame.minX >= 11 && frame.maxX <= CGFloat(h.width - 11))
                    #expect(try target(Self.title, in: graph) === trigger)
                    #expect(!graph.recomposer.hasPending)
                }
            }
            key(Scancode.escape, input); settle(graph, h)
            #expect(portals.entries.isEmpty)
        } }
    }

    @Test("Select commits through its real menu, releases a disabled popup and preserves selected values")
    func selectKeyboardAndDisable() throws {
        try scene(.select) { h, graph, context, input, portals in
            let trigger = try target(Self.title, in: graph)
            context.focusChain.focus(trigger); key(Scancode.return, input); settle(graph, h)
            #expect(trigger.accessibility?.state.isExpanded == true)
            key(Scancode.end, input); key(Scancode.return, input); settle(graph, h)
            #expect(h.selection == 11 && portals.entries.isEmpty && context.focusChain.focused === trigger)
            #expect(trigger.accessibility?.label == "Option 11")
            click(trigger, input); settle(graph, h)
            h.enabled = false; settle(graph, h)
            #expect(portals.entries.isEmpty && context.focusChain.focused == nil && h.selection == 11)
            #expect(trigger.accessibility?.state.isExpanded == false)
        }
    }

    @Test("Combobox list height scales once, includes the touch floor, and search focus survives resize before a commit")
    func comboboxGeometryAndSearch() throws {
        try scene(.combobox) { h, graph, context, input, portals in
            h.scale = 2; h.input = [.touch, .keyboard]; settle(graph, h)
            click(try target(Self.title, in: graph), input); settle(graph, h)
            let search = try #require(context.focusChain.focused)
            #expect(search.accessibility?.label == "Search…")
            let rows = nodes(graph.tree.root).filter { $0.accessibility?.role == .listItem }
            #expect(!rows.isEmpty)
            for row in rows { #expect(abs(row.frame.height - 64) < 1) }
            #expect(nodes(graph.tree.root).contains { $0.clipsToBounds && $0.attachments[ScrollReveal.handlerKey] != nil && abs($0.frame.height - 192) < 1 })
            h.width = 720; h.fieldWidth = 400; settle(graph, h)
            #expect(context.focusChain.focused === search)
            input.dispatch(.textInput("Option 11")); settle(graph, h)
            key(Scancode.return, input); settle(graph, h)
            #expect(h.selection == 11 && portals.entries.isEmpty)
            let clear = try target("Clear selection", in: graph)
            #expect(clear.frame.width >= 44 && clear.frame.height >= 44)
            click(clear, input); settle(graph, h)
            #expect(h.selection == nil)
        }
    }

    @Test("Missing selections keep the full placeholder but expose an empty value and AI reads follow disabled input")
    func placeholderAndAI() throws {
        for kind in Kind.allCases { try scene(kind) { h, graph, _, _, _ in
            h.selection = 99; settle(graph, h)
            let trigger = try target(Self.placeholder, in: graph)
            #expect(trigger.accessibility?.value.isEmpty == true && trigger.accessibility?.help == Self.placeholder)
            let diagnostic = UIDiagnostics(tree: graph.tree)
            @MainActor func count() throws -> Int {
                let response = diagnostic.handleReadRequest(.init(type: "diagnostics.call", payload: .object([
                    "name": .string("query_ui_nodes"), "arguments": .object([
                        "text": .string(Self.placeholder), "role": .string("comboBox"), "visible_only": .bool(true), "input_enabled_only": .bool(true)
                    ])
                ])))
                #expect(response.type == "diagnostics.call.ok")
                let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(response.payload)) as? [String: Any])
                return try #require((json["data"] as? [String: Any])?["total"] as? Int)
            }
            let active = try count(); #expect(active == 1)
            h.enabled = false; settle(graph, h)
            let disabled = try count(); #expect(disabled == 0)
        } }
    }
}
