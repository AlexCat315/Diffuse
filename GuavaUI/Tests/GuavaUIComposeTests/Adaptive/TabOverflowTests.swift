import Foundation
import Testing
import GuavaUIRuntime
import GuavaUIAgent
import GuavaUIDevToolsProtocol
@testable import GuavaUICompose

@Suite("Adaptive tab overflow", .serialized)
@MainActor
struct TabOverflowTests: GuavaUIComposeSerializedSuite {
    private nonisolated static let longTitle = "Workspace permissions 👩🏽‍💻 and international collaboration settings"
    private struct Panel: View {
        @State private var count = 0
        var body: some View { Button("Panel count \(count)") { count += 1 }.accessibilityLabel("Panel count \(count)") }
    }
    private final class Harness: View {
        @State var width: Float = 390
        @State var scale: Float = 1
        @State var input: UIEnvironment.Input = [.pointer, .keyboard]
        @State var dark = false
        @State var rtl = false
        @State var selected = 0
        @State var enabled = true
        @State var variant: TabVariant = .bar
        @State var overflow: TabOverflow = .menu
        @State var removed: Set<Int> = []
        @State var longTitle = false
        var body: some View {
            var surface = UIEnvironment(); surface.viewport.width = width; surface.input = input
            let labels = ["Overview", "Activity", longTitle ? TabOverflowTests.longTitle : "Settings", "Unavailable", "Assets", "History"]
            let tabs = labels.indices.filter { !removed.contains($0) }.map { index in
                TabItem(labels[index], id: index, isEnabled: index != 3, configure: {
                    if index == 0 { $0.icon = UIIcons.File.file; $0.badge = "7" }
                    $0.onClose = { self.removed.insert(index); if self.selected == index { self.selected = 0 } }
                }) { if index == 0 { AnyView(Panel()) } else { AnyView(Text("Panel \(index)")) } }
            }
            return LayerRoot {
                TabView(selection: $selected, tabs: tabs) { $0.overflow = overflow; $0.variant = variant; $0.isEnabled = enabled }
                    .frame(width: .percent(100), height: .percent(100)).debugName("tabs-fixture")
            }.frame(width: width, height: 300).surfaceEnvironment(surface).textScaler(.init(scale))
                .appearance(dark ? .dark : .light).layoutDirection(rtl ? .rtl : .ltr).reducedMotion()
        }
    }
    private func nodes(_ root: Node?) -> [Node] {
        var pending = root.map { [$0] } ?? [], result: [Node] = []
        while let node = pending.popLast() { result.append(node); pending.append(contentsOf: node.children.reversed()) }
        return result
    }
    private func target(_ label: String, role: AccessibilityRole? = nil, in graph: ViewGraph) throws -> Node {
        try #require(nodes(graph.tree.root).first {
            $0.accessibility?.label == label && (role == nil || $0.accessibility?.role == role) && $0.isHitTestable
        })
    }
    private func settle(_ graph: ViewGraph, _ h: Harness) {
        for _ in 0..<8 { graph.recomposer.commitAll(); graph.computeLayout(width: h.width, height: 300) }
    }
    private func scene(_ work: (Harness, ViewGraph, PlatformInputContext, EventDispatcher, PortalStore) throws -> Void) rethrows {
        try GlobalTestLock.locked {
            let old = TextEnvironmentHolder.current; TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = old }
            let context = PlatformInputContext(), portals = PortalStore(), scheduler = AnimatorScheduler()
            context.addScopedAmbient(PortalStoreAmbient(portals))
            try context.withCurrent { try AnimatorScheduler.$current.withValue(scheduler) {
                let h = Harness(), graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
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
        let event = MouseButtonEvent(button: .left, x: Float(f.midX), y: Float(f.midY), clicks: 1)
        input.dispatch(.mouseButtonDown(event)); input.dispatch(.mouseButtonUp(event))
    }
    private func key(_ code: UInt32, _ input: EventDispatcher) {
        input.dispatch(.keyDown(.init(scancode: code, keycode: 0, modifiers: [], isRepeat: false)))
    }

    @Test("Menu layout retains the active panel and headers across width, scale, input, theme, direction and variant")
    func matrix() throws {
        try scene { h, graph, _, input, _ in
            let overview = try target("Overview", role: .tab, in: graph)
            let initialCounter = try target("Panel count 0", in: graph)
            let f = initialCounter.absoluteFrame
            let hit = HitTester.hitTest(rootNode: try #require(graph.tree.root), point: CGPoint(x: f.midX, y: f.midY))?.node
            #expect(hit === initialCounter, "Counter frame \(f), hit \(hit?.accessibility?.label ?? "none")")
            click(initialCounter, input); settle(graph, h)
            let panel = try target("Panel count 1", in: graph)
            for width: Float in [390, 720, 1280] { for scale: Float in [1, 2] {
                for modality: UIEnvironment.Input in [[.touch], [.touch, .pointer, .keyboard], [.pointer, .keyboard]] {
                    for dark in [false, true] { for rtl in [false, true] { for variant: TabVariant in [.bar, .segmented, .card] {
                        h.width = width; h.scale = scale; h.input = modality; h.dark = dark; h.rtl = rtl; h.variant = variant; settle(graph, h)
                        #expect(try target("Overview", role: .tab, in: graph) === overview)
                        #expect(try target("Panel count 1", in: graph) === panel)
                        let tabs = nodes(graph.tree.root).filter { $0.accessibility?.role == .tab && $0.isHitTestable && $0.acceptsSubtreeInput }
                        #expect(!tabs.isEmpty && overview.acceptsSubtreeInput)
                        for tab in tabs {
                            #expect(tab.absoluteFrame.minX >= -1 && tab.absoluteFrame.maxX <= CGFloat(width) + 1)
                            if modality.contains(.touch) { #expect(tab.frame.width >= 44 && tab.frame.height >= 44) }
                        }
                        if let more = nodes(graph.tree.root).first(where: { $0.accessibility?.label == "More tabs" && $0.isFocusable && $0.acceptsSubtreeInput }) {
                            #expect(more.frame.width >= 44 && more.frame.height >= 44 && more.isTabStop)
                        }
                        if width == 390 { #expect(panel.absoluteFrame.maxY <= overview.absoluteFrame.minY) }
                        #expect(!graph.recomposer.hasPending)
                    } } }
                }
            } }
        }
    }

    @Test("Menu rows preserve disabled semantics, activate hidden tabs, restore focus and close on Escape or disable")
    func menu() throws {
        try scene { h, graph, context, input, portals in
            h.width = 240; h.input = [.touch, .keyboard]; settle(graph, h)
            let more = try target("More tabs", in: graph)
            click(more, input); settle(graph, h)
            let disabled = try target("Unavailable", role: .button, in: graph)
            #expect(disabled.accessibility?.state.isEnabled == false && disabled.frame.height >= 44)
            key(Scancode.end, input); key(Scancode.return, input); settle(graph, h)
            #expect(h.selected == 5 && portals.entries.isEmpty)
            let active = try target("History", role: .tab, in: graph)
            #expect(active.acceptsSubtreeInput && context.focusChain.focused === active)
            click(try target("More tabs", in: graph), input); settle(graph, h)
            key(Scancode.escape, input); settle(graph, h)
            #expect(portals.entries.isEmpty && context.focusChain.focused === more)
            click(more, input); settle(graph, h)
            h.enabled = false; settle(graph, h)
            #expect(portals.entries.isEmpty && context.pointerCapture.target == nil)
            #expect(context.focusChain.focused == nil)
        }
    }

    @Test("Two arrow commands in one frame can select hidden headers and resolve actual focus after placement")
    func hiddenKeyboardTarget() throws {
        try scene { h, graph, context, input, _ in
            h.width = 240; settle(graph, h)
            context.focusChain.focus(try target("Overview", role: .tab, in: graph))
            key(Scancode.end, input); key(Scancode.arrowLeft, input)
            #expect(h.selected == 4)
            settle(graph, h)
            let assets = try target("Assets", role: .tab, in: graph)
            #expect(assets.acceptsSubtreeInput && context.focusChain.focused === assets && assets.isTabStop)
            key(Scancode.arrowLeft, input); settle(graph, h)
            #expect(h.selected == 2)
        }
    }

    @Test("A long selected header stays one line with full semantics and tooltip while icon, badge and close remain reachable")
    func truncation() throws {
        try scene { h, graph, _, _, _ in
            h.width = 240; h.longTitle = true; h.selected = 2; h.scale = 2; settle(graph, h)
            for mode: TabOverflow in [.wrap, .scroll, .menu] {
                h.overflow = mode; settle(graph, h)
                let active = try target(Self.longTitle, role: .tab, in: graph)
                #expect(active.accessibility?.help == Self.longTitle)
                ScrollReveal.reveal(active); settle(graph, h)
                #expect(active.absoluteFrame.maxX <= CGFloat(h.width), "Header frame \(active.frame), absolute \(active.absoluteFrame)")
                let text = try #require(nodes(active).first { $0.layoutNode?.textInputs?.text == Self.longTitle })
                let layout = try #require(text.layoutNode)
                let list = DrawList(); NodeRenderer().render(root: try #require(graph.tree.root), into: list)
                #expect(layout.textInputs?.lineLimit == 1 && text.clipsToBounds)
                #expect((layout.textMeasure?.result.lines.count ?? 0) <= 1)
                #expect((layout.textMeasure?.result.totalWidth ?? .infinity) <= Float(text.frame.width) + 1)
                let close = try target("Close \(Self.longTitle)", role: .button, in: graph)
                #expect(close.acceptsSubtreeInput)
            }
        }
    }

    @Test("Validated AI queries expose visible tabs and the reachable menu, excluding hidden headers")
    func aiQueries() throws {
        try scene { h, graph, _, _, _ in
            h.width = 240; settle(graph, h)
            let diagnostics = UIDiagnostics(tree: graph.tree)
            @MainActor func count(_ label: String, _ role: String) throws -> Int {
                let response = diagnostics.handleReadRequest(.init(type: "diagnostics.call", payload: .object([
                    "name": .string("query_ui_nodes"), "arguments": .object([
                        "text": .string(label), "role": .string(role), "visible_only": .bool(true), "input_enabled_only": .bool(true)
                    ])
                ])))
                #expect(response.type == "diagnostics.call.ok")
                let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(response.payload)) as? [String: Any])
                return try #require((json["data"] as? [String: Any])?["total"] as? Int)
            }
            let hidden = try count("History", "tab"), more = try count("More tabs", "button")
            #expect(hidden == 0 && more == 1)
            h.selected = 5; settle(graph, h)
            let shown = try count("History", "tab"); #expect(shown == 1)
            h.width = 1280; settle(graph, h)
            let allFit = try count("More tabs", "button"); #expect(allFit == 0)
        }
    }

    @Test("A menu closes when every header fits again and restores focus to the retained selected header")
    func menuResize() throws {
        try scene { h, graph, context, input, portals in
            h.width = 240; settle(graph, h)
            let selected = try target("Overview", role: .tab, in: graph)
            click(try target("More tabs", in: graph), input); settle(graph, h)
            #expect(!portals.entries.isEmpty)
            h.width = 1280; settle(graph, h)
            #expect(portals.entries.isEmpty && context.focusChain.focused === selected)
            #expect(try target("Overview", role: .tab, in: graph) === selected)
            h.width = 240; settle(graph, h)
            click(try target("More tabs", in: graph), input); settle(graph, h)
            h.removed.insert(5); settle(graph, h)
            #expect(portals.entries.isEmpty)
            #expect(!nodes(graph.tree.root).contains { $0.accessibility?.label == "History" })
        }
    }

    @Test("An extremely narrow strip scrolls without overlapping its icon, badge, close control or menu entrance")
    func chromeMinimum() throws {
        try scene { h, graph, _, _, _ in
            h.width = 80; h.input = [.touch, .keyboard]; h.scale = 2; settle(graph, h)
            let selected = try target("Overview", role: .tab, in: graph)
            let close = try target("Close Overview", role: .button, in: graph)
            let more = try target("More tabs", in: graph)
            #expect(close.frame.width >= 44 && close.frame.height >= 44)
            #expect(close.absoluteFrame.maxX <= selected.absoluteFrame.maxX,
                    "Header \(selected.absoluteFrame), close \(close.absoluteFrame), minimum \(String(describing: selected.layoutNode?.minWidth))")
            #expect(selected.absoluteFrame.maxX <= more.absoluteFrame.minX)
            ScrollReveal.reveal(more); settle(graph, h)
            let query = try UIDiagnostics(tree: graph.tree).queryNodes(text: "More tabs", role: "button", visibleOnly: true)
            #expect(query.total == 1 && (query.items.first?.presentation.visibleFrame?.w ?? 0) >= 44)
        }
    }
}
