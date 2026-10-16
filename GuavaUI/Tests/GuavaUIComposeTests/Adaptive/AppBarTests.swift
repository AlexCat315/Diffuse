import Foundation
import GuavaUIAgent
import GuavaUIRuntime
import Testing
@testable import GuavaUICompose

@Suite("Adaptive application bar", .serialized)
@MainActor
struct AppBarTests: GuavaUIComposeSerializedSuite {
    nonisolated private static let title = "Workspace permissions · 用户设置 · 👩🏽‍💻 project with a long document title"
    private final class Harness: View {
        @State var width: Float = 1280
        @State var scale: Float = 1
        @State var input: UIEnvironment.Input = [.pointer, .keyboard]
        @State var dark = false
        @State var enabled = true
        @State var backEnabled = true
        @State var bare = false
        @State var textPrimary = false
        @State var title = AppBarTests.title
        @State var safe = false
        @State var rtl = false
        @State var calls = 0
        var body: some View {
            var environment = UIEnvironment(); environment.input = input
            environment.viewport.width = 1280 // Container allocation must select compact mode.
            return LayerRoot {
                Box(direction: .column, alignItems: .stretch) {
                    SafeArea {
                        SafeArea {
                            AppBar(title, subtitle: "Saved locally · All changes synchronized",
                                back: bare ? nil : MenuItem(id: "back", title: "Go back", isEnabled: backEnabled) { self.calls += 1 },
                                primary: bare ? nil : ToolbarItem(MenuItem(id: "save", title: textPrimary ? "Save workspace with a deliberately long command label" : "Save") { self.calls += 10 },
                                    icon: textPrimary ? nil : .resource(UIIcons.Action.check)),
                                actions: bare ? [] : [
                                    ToolbarItem(MenuItem(id: "find", title: "Find") { self.calls += 100 }, icon: .resource(UIIcons.Action.search), placement: .automatic(priority: 10)),
                                    ToolbarItem(MenuItem(id: "export", title: "Export") { self.calls += 1_000 }, icon: .resource(UIIcons.Action.download)),
                                    ToolbarItem(MenuItem(id: "share", title: "Share") { self.calls += 10_000 }, icon: .resource(UIIcons.Action.share)),
                                    ToolbarItem(MenuItem(id: "pin", title: "Pin", isSelected: true) { self.calls += 100_000 }, placement: .overflow),
                                    ToolbarItem(MenuItem(id: "disabled", title: "Unavailable", isEnabled: false) { self.calls += 1_000_000 })
                                ], configure: { $0.isEnabled = enabled })
                                .debugName("appbar-fixture")
                        }
                    }.safeAreaInsets(safe ? EdgeInsets(top: 24, leading: 11, bottom: 0, trailing: 19) : .zero)
                    Button("After bar") {}.accessibilityLabel("After bar")
                }.flex(1, shrink: 1, basis: 0)
            }.frame(width: width, height: 640).surfaceEnvironment(environment).textScaler(.init(scale))
                .appearance(dark ? .dark : .light).layoutDirection(rtl ? .rtl : .ltr).reducedMotion()
        }
    }
    private func nodes(_ root: Node?) -> [Node] {
        var pending = root.map { [$0] } ?? [], result: [Node] = []
        while let node = pending.popLast() { result.append(node); pending.append(contentsOf: node.children.reversed()) }
        return result
    }
    private func button(_ label: String, _ graph: ViewGraph) throws -> Node {
        try #require(nodes(graph.tree.root).first { $0.accessibility?.label == label && $0.isFocusable })
    }
    private func bar(_ graph: ViewGraph) throws -> Node {
        try #require(nodes(graph.tree.root).first { $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == "appbar-fixture" })
    }
    private func heading(_ graph: ViewGraph) throws -> Node { try #require(nodes(graph.tree.root).first { $0.accessibility?.role == .heading }) }
    private func settle(_ graph: ViewGraph, _ harness: Harness) {
        for _ in 0..<10 { graph.recomposer.commitAll(); graph.computeLayout(width: harness.width, height: 640) }
    }
    private func scene(_ work: (Harness, ViewGraph, PlatformInputContext, EventDispatcher, AnimatorScheduler, PortalStore) throws -> Void) rethrows {
        try GlobalTestLock.locked {
            let previous = TextEnvironmentHolder.current; TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = previous }
            let context = PlatformInputContext(), scheduler = AnimatorScheduler(), portals = PortalStore()
            context.addScopedAmbient(PortalStoreAmbient(portals))
            try context.withCurrent { try AnimatorScheduler.$current.withValue(scheduler) {
                let harness = Harness(), graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                let input = EventDispatcher(tree: graph.tree, interactions: context.interactions, capture: context.pointerCapture, focusChain: context.focusChain)
                graph.install(root: harness); settle(graph, harness)
                defer { graph.install(root: EmptyView()); scheduler.reset() }
                try work(harness, graph, context, input, scheduler, portals)
            } }
        }
    }
    private func key(_ code: UInt32, _ input: EventDispatcher) {
        input.dispatch(.keyDown(.init(scancode: code, keycode: 0, modifiers: [], isRepeat: false)))
    }
    private func click(_ node: Node, _ input: EventDispatcher) {
        let frame = node.absoluteFrame
        let event = MouseButtonEvent(button: .left, x: Float(frame.midX), y: Float(frame.midY), clicks: 1)
        input.dispatch(.mouseButtonDown(event)); input.dispatch(.mouseButtonUp(event))
    }

    @Test("Three widths retain commands, fit titles and keep targets across input, theme and text scaling",
          arguments: [Float(390), 720, 1280], [Float(1), 2])
    func geometry(width: Float, scale: Float) throws {
        try scene { harness, graph, _, _, _, _ in
            let original = try button("Save", graph).id
            for capabilities: UIEnvironment.Input in [[.touch], [.touch, .pointer, .keyboard], [.pointer, .keyboard]] {
                for dark in [false, true] {
                    harness.width = width; harness.scale = scale; harness.input = capabilities; harness.dark = dark
                    settle(graph, harness)
                    #expect(try button("Save", graph).id == original)
                    let chrome = try bar(graph)
                    #expect(chrome.frame.height >= 48 && chrome.frame.width == CGFloat(width))
                    let visible = nodes(chrome).filter { $0.isFocusable && $0.acceptsSubtreeInput }
                    #expect(visible.count == (width < 600 ? 3 : 5))
                    for node in visible {
                        #expect(node.frame.height >= 44 && node.frame.width >= 44)
                        #expect(node.absoluteFrame.minX >= 0 && node.absoluteFrame.maxX <= CGFloat(width) + 1)
                    }
                    let name = try heading(graph)
                    #expect(name.accessibility?.label == Self.title && !name.isFocusable)
                    let text = try #require(nodes(name).first { $0.layoutNode?.textInputs?.text == Self.title })
                    let measured = try #require(text.layoutNode?.textMeasure)
                    #expect(measured.result.lines.count <= 1 && measured.result.totalWidth <= Float(text.frame.width) + 1)
                    if width == 390 { #expect(measured.key.text.hasSuffix("…")) }
                    #expect(!graph.recomposer.hasPending)
                }
            }
        }
    }

    @Test("Long primary labels truncate while overflow remains visible; safe area is consumed exactly once in either direction")
    func boundedPrimaryAndInsets() throws {
        try scene { harness, graph, _, _, _, _ in
            harness.width = 390; harness.textPrimary = true; harness.safe = true; harness.scale = 2
            for rtl in [false, true] {
                harness.rtl = rtl; settle(graph, harness)
                let chrome = try bar(graph), more = try button("More actions", graph)
                #expect(chrome.absoluteFrame.minY == 24 && chrome.frame.width == 360)
                #expect(chrome.absoluteFrame.minX == (rtl ? 19 : 11))
                #expect(more.frame.width >= 44 && more.absoluteFrame.maxX <= 390 && more.absoluteFrame.minX >= 0)
                let visible = try UIDiagnostics(tree: graph.tree).queryNodes(text: "More actions", role: "button", visibleOnly: true)
                #expect((visible.items.first?.presentation.visibleFrame?.w ?? 0) >= Double(more.frame.width) - 1)
                let text = try #require(nodes(chrome).first { $0.layoutNode?.textInputs?.text.hasPrefix("Save workspace") == true })
                #expect(text.layoutNode?.textMeasure?.key.text.hasSuffix("…") == true)
                #expect(text.layoutNode?.textMeasure?.result.totalWidth ?? .infinity <= Float(text.frame.width) + 1)
            }
        }
    }

    @Test("Tab order, menu keyboard activation, selected/disabled commands and focus restoration share Toolbar behavior")
    func keyboardAndMenu() throws {
        try scene { harness, graph, context, input, _, portals in
            harness.width = 390; settle(graph, harness)
            context.focusChain.clear()
            for title in ["Go back", "Save", "More actions", "After bar"] {
                key(Scancode.tab, input)
                #expect(context.focusChain.focused?.accessibility?.label == title)
            }
            let more = try button("More actions", graph)
            let hover = more.absoluteFrame
            input.dispatch(.mouseMotion(.init(x: Float(hover.midX), y: Float(hover.midY), deltaX: 0, deltaY: 0)))
            settle(graph, harness)
            #expect(nodes(more).contains { $0.backgroundColor == more.theme.colors.stateLayerHover })
            context.focusChain.focus(more); key(Scancode.return, input); settle(graph, harness)
            #expect(more.accessibility?.state.isExpanded == true && !portals.entries.isEmpty)
            let rows = nodes(graph.tree.root).filter { $0.attachments["__menu_item_id"] != nil }
            #expect(rows.allSatisfy { $0.frame.height >= 44 })
            #expect(rows.contains { $0.accessibility?.label == "Pin" && $0.accessibility?.state.isSelected == true })
            let disabled = try #require(rows.first { $0.accessibility?.label == "Unavailable" })
            #expect(disabled.accessibilityActions.activate == nil)
            key(Scancode.home, input); key(Scancode.return, input); settle(graph, harness)
            #expect(harness.calls == 100 && portals.entries.isEmpty)
            #expect(context.focusChain.focused?.id == more.id && more.accessibility?.state.isExpanded == false)
            click(try button("Go back", graph), input); click(try button("Save", graph), input); settle(graph, harness)
            #expect(harness.calls == 111)
        }
    }

    @Test("Resize closes a changing menu and moves hidden command focus; disabled bars cancel capture and leave the page usable")
    func lifecycle() throws {
        try scene { harness, graph, context, input, _, portals in
            let find = try button("Find", graph)
            context.focusChain.focus(find); harness.width = 390; settle(graph, harness)
            let more = try button("More actions", graph)
            #expect(context.focusChain.focused?.id == more.id)
            click(more, input); settle(graph, harness); #expect(!portals.entries.isEmpty)
            harness.width = 1280; settle(graph, harness)
            #expect(portals.entries.isEmpty && find.acceptsSubtreeInput)
            let save = try button("Save", graph), frame = save.absoluteFrame
            input.dispatch(.mouseButtonDown(.init(button: .left, x: Float(frame.midX), y: Float(frame.midY), clicks: 1)))
            #expect(context.pointerCapture.target != nil)
            harness.enabled = false; settle(graph, harness)
            #expect(context.pointerCapture.target == nil && !save.acceptsSubtreeInput)
            click(save, input); #expect(harness.calls == 0)
            #expect(try button("After bar", graph).acceptsSubtreeInput)
            graph.install(root: EmptyView()); #expect(portals.entries.isEmpty && !context.focusChain.hasModalScope)
        }
    }

    @Test("The title tooltip and semantics retain the original Unicode string while live edits update the heading")
    func titleDescription() throws {
        try scene { harness, graph, _, input, scheduler, portals in
            harness.width = 390; settle(graph, harness)
            let title = try heading(graph), frame = title.absoluteFrame
            input.dispatch(.mouseMotion(.init(x: Float(frame.midX), y: Float(frame.midY), deltaX: 0, deltaY: 0)))
            scheduler.tick(deltaTime: 1); settle(graph, harness)
            #expect(!portals.entries.isEmpty)
            #expect(nodes(graph.tree.root).contains { $0.layoutNode?.textInputs?.text == Self.title && $0 !== title })
            harness.title = "Updated 👩🏽‍💻 title"; settle(graph, harness)
            #expect(title.id == (try heading(graph)).id && title.accessibility?.label == harness.title)
        }
    }

    @Test("An individually disabled back action preserves other commands; title-only headers have no phantom menu or Tab stop")
    func optionalSlots() throws {
        try scene { harness, graph, _, input, _, _ in
            harness.width = 390; harness.backEnabled = false; settle(graph, harness)
            let back = try #require(nodes(graph.tree.root).first { $0.accessibility?.label == "Go back" && $0.attachments[ButtonHost.markerKey] != nil })
            #expect(back.accessibility?.state.isEnabled == false && back.accessibilityActions.activate == nil)
            click(back, input); click(try button("Save", graph), input); settle(graph, harness)
            #expect(harness.calls == 10)
            harness.bare = true; settle(graph, harness)
            let chrome = try bar(graph)
            #expect(chrome.frame.height >= 48 && chrome.frame.width == 390)
            #expect(!nodes(chrome).contains { $0.isFocusable && $0.acceptsSubtreeInput })
            #expect(try heading(graph).accessibility?.label == Self.title)
        }
    }

    @Test("Validated AI queries find full headings and only the available inline or menu representation of a command")
    func aiQueries() async throws {
        let prepared = GlobalTestLock.locked {
            let previous = TextEnvironmentHolder.current; TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = previous }
            let context = PlatformInputContext(), scheduler = AnimatorScheduler(), portals = PortalStore()
            context.addScopedAmbient(PortalStoreAmbient(portals))
            return context.withCurrent { AnimatorScheduler.$current.withValue(scheduler) {
                let harness = Harness(); harness.width = 390
                let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                graph.install(root: harness); settle(graph, harness)
                return (harness, graph, context, scheduler)
            } }
        }
        let (harness, graph, context, scheduler) = prepared
        defer { GlobalTestLock.locked { context.withCurrent { graph.install(root: EmptyView()); scheduler.reset() } } }
        let diagnostics = UIDiagnostics(tree: graph.tree, state: graph.stateRegistry)
        let toolbox = try diagnostics.toolbox()
        let headingInput = try JSONSerialization.data(withJSONObject: ["text": Self.title, "role": "heading", "visible_only": true])
        let headingResult = try await toolbox.execute(name: "query_ui_nodes", input: headingInput)
        let headingResponse = try #require(JSONSerialization.jsonObject(with: headingResult.json) as? [String: Any])
        let headingData = try #require(headingResponse["data"] as? [String: Any])
        #expect(headingData["total"] as? Int == 1)
        let items = try #require(headingData["items"] as? [[String: Any]])
        let semantics = try #require(items.first?["semantics"] as? [String: Any])
        #expect(semantics["label"] as? String == Self.title)
        try GlobalTestLock.locked { try context.withCurrent {
            let more = try button("More actions", graph)
            context.focusChain.focus(more); more.accessibilityActions.activate?(); settle(graph, harness)
        } }
        for (text, count) in [("Find", 1), ("Unavailable", 0)] {
            let input = try JSONSerialization.data(withJSONObject: ["text": text, "role": "button", "visible_only": true, "input_enabled_only": true])
            let result = try await toolbox.execute(name: "query_ui_nodes", input: input)
            let response = try #require(JSONSerialization.jsonObject(with: result.json) as? [String: Any])
            let data = try #require(response["data"] as? [String: Any])
            #expect(data["total"] as? Int == count)
        }
    }
}
