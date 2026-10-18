import Foundation
import Testing
import GuavaUIRuntime
import GuavaUIAgent
import GuavaUIDevToolsProtocol
@testable import GuavaUICompose

@Suite("Action sheet", .serialized)
@MainActor
struct ActionSheetTests: GuavaUIComposeSerializedSuite {
    private final class Harness: View {
        @State var open = false
        @State var enabled = true
        @State var mounted = true
        @State var width: Float = 1280
        @State var height: Float = 820
        @State var scale: Float = 1
        @State var dark = false
        @State var rtl = false
        @State var touch = false
        @State var long = false
        @State var result = "None"
        @State var calls = 0
        @State var safeBottom: Float = 0
        @State var closeLabel = "Dismiss actions"
        var body: some View {
            var surface = UIEnvironment(); surface.viewport.width = width; surface.viewport.height = height
            surface.input = touch ? [.touch, .keyboard] : [.pointer, .keyboard]; surface.safeArea.bottom = safeBottom
            let actions = long ? (0..<30).map { index in
                ActionSheetAction("\(index)", "Workspace action \(index)") { self.result = "\(index)"; self.calls += 1 }
            } : [ActionSheetAction("duplicate", "Duplicate project", icon: UIIcons.Action.copy) { self.result = "Duplicated"; self.calls += 1 },
                 ActionSheetAction("export", "Export project", isEnabled: false) { self.result = "Exported" },
                 ActionSheetAction("delete", "Delete project", role: .destructive) { self.result = "Deleted"; self.calls += 1 }]
            return LayerRoot {
                if mounted {
                    ActionSheet(isPresented: $open, title: "Project actions", message: "Choose what happens to this project.",
                        actions: actions, closeLabel: closeLabel, isEnabled: enabled) { Text("More actions") }
                        .absolutePosition(left: 80, top: 150)
                }
                Button("After sheet") {}.absolutePosition(left: 80, top: 220)
            }.frame(width: width, height: height).surfaceEnvironment(surface).textScaler(.init(scale))
                .appearance(dark ? .dark : .light).layoutDirection(rtl ? .rtl : .ltr).reducedMotion()
        }
    }
    private func nodes(_ root: Node?) -> [Node] { root.map { [$0] + $0.children.flatMap { nodes($0) } } ?? [] }
    private func button(_ label: String, _ graph: ViewGraph) throws -> Node {
        try #require(nodes(graph.tree.root).first { node in
            node.accessibility?.role == .button && (node.accessibility?.label == label
                || nodes(node).contains { $0.layoutNode?.textInputs?.text == label })
        })
    }
    private func panel(_ graph: ViewGraph) throws -> Node {
        try #require(nodes(graph.tree.root).first { $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == "action-sheet-content" })
    }
    private func handle(_ graph: ViewGraph) throws -> Node {
        try #require(nodes(graph.tree.root).first { $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == "action-sheet-handle" })
    }
    private func close(_ h: Harness, _ graph: ViewGraph) throws -> Node { try button(h.closeLabel, graph) }
    private func separators(_ graph: ViewGraph) -> [Node] {
        nodes(graph.tree.root).filter {
            ($0.attachments[LayoutDebugAttachmentKey.debugName] as? String)?.hasPrefix("action-sheet-separator-") == true
        }
    }
    private func settle(_ graph: ViewGraph, _ h: Harness) {
        for _ in 0..<8 { graph.recomposer.commitAll(); graph.computeLayout(width: h.width, height: h.height) }
    }
    private func key(_ code: UInt32, _ input: EventDispatcher) {
        input.dispatch(.keyDown(.init(scancode: code, keycode: 0, modifiers: [], isRepeat: false)))
        input.dispatch(.keyUp(.init(scancode: code, keycode: 0, modifiers: [], isRepeat: false)))
    }
    private func scene(_ work: (Harness, ViewGraph, PlatformInputContext, PortalStore, EventDispatcher) throws -> Void) rethrows {
        try GlobalTestLock.locked {
            let old = TextEnvironmentHolder.current; TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = old }
            let context = PlatformInputContext(), store = PortalStore()
            context.addScopedAmbient(PortalStoreAmbient(store))
            try context.withCurrent { try AnimatorScheduler.$current.withValue(AnimatorScheduler()) {
                let h = Harness(), graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                let input = EventDispatcher(tree: graph.tree, interactions: context.interactions, capture: context.pointerCapture, focusChain: context.focusChain)
                graph.install(root: h); settle(graph, h)
                defer { graph.install(root: EmptyView()) }
                try work(h, graph, context, store, input)
            } }
        }
    }
    @Test("Actions close before execution, the top close control only dismisses, and focus returns")
    func lifecycle() throws {
        try scene { h, graph, context, store, input in
            let trigger = try button("More actions", graph)
            context.focusChain.focus(trigger); key(Scancode.return, input); settle(graph, h)
            let first = try button("Duplicate project", graph)
            #expect(store.entries.count == 1 && context.focusChain.focused === first && trigger.accessibility?.state.isExpanded == true)
            #expect(!nodes(first).contains { $0.borderWidth > 0 && $0.borderColor == first.theme.colors.focusRing })
            #expect(nodes(first).contains { $0.backgroundColor == first.theme.colors.stateLayerHover })
            #expect(try button("Export project", graph).accessibility?.state.isEnabled == false)
            key(Scancode.arrowDown, input); settle(graph, h)
            #expect(context.focusChain.focused === (try button("Delete project", graph)))
            key(Scancode.home, input); settle(graph, h)
            key(Scancode.tab, input); settle(graph, h)
            #expect(context.focusChain.focused === (try close(h, graph)))
            key(Scancode.return, input); settle(graph, h)
            #expect(!h.open && h.result == "None" && store.entries.isEmpty && context.focusChain.focused === trigger)
            trigger.accessibilityActions.activate?(); settle(graph, h)
            key(Scancode.escape, input); settle(graph, h)
            #expect(!h.open && h.result == "None" && context.focusChain.focused === trigger)
            for width: Float in [390, 1280] {
                h.width = width; settle(graph, h)
                trigger.accessibilityActions.activate?(); settle(graph, h)
                let outside = MouseButtonEvent(button: .left, x: width - 20, y: 20, clicks: 1)
                input.dispatch(.mouseButtonDown(outside)); input.dispatch(.mouseButtonUp(outside)); settle(graph, h)
                #expect(!h.open && h.calls == 0 && store.entries.isEmpty)
            }
            trigger.accessibilityActions.activate?(); settle(graph, h)
            let action = try button("Delete project", graph).accessibilityActions.activate
            action?(); settle(graph, h); action?()
            #expect(!h.open && h.result == "Deleted" && h.calls == 1 && store.entries.isEmpty)
        }
    }
    @Test("Compact uses a content-sized bottom drawer with a handle, safe-area clearance and a scrolling action list")
    func compact() throws {
        try scene { h, graph, context, _, input in
            h.width = 390; h.touch = true; h.safeBottom = 34; settle(graph, h)
            try button("More actions", graph).accessibilityActions.activate?(); settle(graph, h)
            let frame = try panel(graph).absoluteFrame
            #expect(frame.width <= 390 && frame.width > 300)
            #expect(frame.height < 500)
            #expect(frame.minY > 300)
            #expect(try handle(graph).absoluteFrame.height >= 44)
            #expect(try handle(graph).absoluteFrame.width >= 300)
            #expect(!nodes(graph.tree.root).contains { $0.accessibility?.label == h.closeLabel })
            #expect(!nodes(graph.tree.root).contains { $0.accessibility?.label == "Cancel" })
            #expect(separators(graph).count == 2)
            let row = try button("Duplicate project", graph)
            let text = try #require(nodes(row).first { $0.layoutNode?.textInputs?.text == "Duplicate project" })
            #expect(text.absoluteFrame.minX < row.absoluteFrame.minX + 60)
            h.long = true; h.scale = 2; h.height = 520; settle(graph, h)
            #expect(try panel(graph).absoluteFrame.minY >= 11)
            key(Scancode.end, input); settle(graph, h)
            #expect(try button("Workspace action 29", graph).accessibility?.label == "Workspace action 29")
            let last = try button("Workspace action 29", graph).absoluteFrame
            #expect(last.minY >= 12 && last.maxY <= 486)
            key(Scancode.return, input); settle(graph, h)
            #expect(h.result == "29" && !h.open)
        }
    }
    @Test("Dragging the compact handle down closes; a short drag snaps back")
    func drag() throws {
        try scene { h, graph, _, store, input in
            h.width = 390; h.touch = true; settle(graph, h)
            try button("More actions", graph).accessibilityActions.activate?(); settle(graph, h)
            let start = try handle(graph).absoluteFrame
            let origin = try panel(graph).absoluteFrame
            let x = Float(start.midX)
            input.dispatch(.mouseButtonDown(MouseButtonEvent(button: .left, x: x, y: Float(start.midY), clicks: 1)))
            input.dispatch(.mouseMotion(MouseMotionEvent(x: x, y: Float(start.midY + 40), deltaX: 0, deltaY: 40)))
            settle(graph, h)
            #expect(try panel(graph).absoluteFrame.minY > origin.minY + 20)
            input.dispatch(.mouseButtonUp(MouseButtonEvent(button: .left, x: x, y: Float(start.midY + 40), clicks: 1)))
            settle(graph, h)
            #expect(h.open && store.entries.count == 1)
            input.dispatch(.mouseButtonDown(MouseButtonEvent(button: .left, x: x, y: Float(start.midY), clicks: 1)))
            input.dispatch(.mouseMotion(MouseMotionEvent(x: x, y: Float(start.midY + 120), deltaX: 0, deltaY: 120)))
            input.dispatch(.mouseButtonUp(MouseButtonEvent(button: .left, x: x, y: Float(start.midY + 120), clicks: 1)))
            settle(graph, h)
            #expect(!h.open && store.entries.isEmpty)
        }
    }
    @Test("Open presentation stays a drawer across phone and desktop without replacing its trigger or duplicating portals")
    func resize() throws {
        try scene { h, graph, context, store, _ in
            let trigger = try button("More actions", graph)
            trigger.accessibilityActions.activate?(); settle(graph, h)
            for width: Float in [390, 720, 1280, 390] {
                h.width = width; settle(graph, h)
                let currentTrigger = try button("More actions", graph)
                #expect(h.open && store.entries.count == 1 && currentTrigger === trigger)
                #expect(context.focusChain.focused?.acceptsSubtreeInput == true)
                let frame = try panel(graph).absoluteFrame
                #expect(frame.minX >= 0 && frame.maxX <= CGFloat(width))
                #expect(!nodes(graph.tree.root).contains {
                    $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == "anchored-surface"
                })
                if width == 390 {
                    #expect(try handle(graph).frame.height >= 44)
                    #expect(!nodes(graph.tree.root).contains { $0.accessibility?.label == h.closeLabel })
                } else {
                    #expect(!nodes(graph.tree.root).contains {
                        $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == "action-sheet-handle"
                    })
                    #expect(try close(h, graph).accessibility?.label == h.closeLabel)
                }
                #expect(!graph.recomposer.hasPending)
            }
            h.enabled = false; settle(graph, h)
            #expect(!h.open && store.entries.isEmpty)
            h.enabled = true; settle(graph, h)
            trigger.accessibilityActions.activate?(); settle(graph, h)
            h.mounted = false; settle(graph, h)
            #expect(store.entries.isEmpty)
        }
    }
    @Test("Rows retain names, targets, contrast roles and finite geometry across widths, scale, themes, input and RTL")
    func matrix() throws {
        try scene { h, graph, _, store, _ in
            try button("More actions", graph).accessibilityActions.activate?(); settle(graph, h)
            for width: Float in [390, 720, 1280] { for scale: Float in [1, 2] {
                for dark in [false, true] { for rtl in [false, true] { for touch in [false, true] {
                    h.width = width; h.scale = scale; h.dark = dark; h.rtl = rtl; h.touch = touch; settle(graph, h)
                    let p = try panel(graph).absoluteFrame
                    #expect(store.entries.count == 1 && p.minX >= 0 && p.maxX <= CGFloat(width) && p.minY >= 0 && p.maxY <= CGFloat(h.height))
                    if width < 600 {
                        #expect(!nodes(graph.tree.root).contains { $0.accessibility?.label == h.closeLabel })
                    } else {
                        let close = try close(h, graph)
                        #expect(close.frame.height >= 44 && close.frame.width >= 44)
                        #expect(close.accessibility?.label == h.closeLabel)
                    }
                    for label in ["Duplicate project", "Export project", "Delete project"] {
                        let row = try button(label, graph)
                        #expect(row.frame.height >= 44 && row.frame.width > 100)
                        #expect(row.accessibility?.label == label)
                    }
                    #expect(!nodes(graph.tree.root).contains { $0.accessibility?.label == "Cancel" })
                    let list = DrawList(); NodeRenderer().render(root: try #require(graph.tree.root), into: list)
                    #expect(!list.vertices.isEmpty && !graph.recomposer.hasPending)
                } } }
            } }
        }
    }
    @Test("AI discovers the named drawer and close control, then loses them after dismissal")
    func discovery() throws {
        try scene { h, graph, _, _, _ in
            try button("More actions", graph).accessibilityActions.activate?(); settle(graph, h)
            @MainActor func query(_ role: String, _ text: String) throws -> Int {
                let result = UIDiagnostics(tree: graph.tree).handleReadRequest(.init(type: "diagnostics.call", payload: .object([
                    "name": .string("query_ui_nodes"), "arguments": .object([
                        "role": .string(role), "text": .string(text), "visible_only": .bool(true), "input_enabled_only": .bool(true)
                    ])
                ])))
                let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(result.payload)) as? [String: Any])
                return (json["data"] as? [String: Any])?["total"] as? Int ?? -1
            }
            #expect(try query("dialog", "Project actions") == 1)
            #expect(try query("button", "Duplicate project") == 1)
            #expect(try query("button", "Export project") == 0)
            #expect(try query("button", h.closeLabel) == 1)
            try close(h, graph).accessibilityActions.activate?(); settle(graph, h)
            #expect(try query("dialog", "Project actions") == 0)
            #expect(try query("button", h.closeLabel) == 0)
        }
    }
    @Test("The close control takes its accessibility name from the caller, including non-English copy")
    func closeLabelLocalization() throws {
        try scene { h, graph, _, _, _ in
            h.closeLabel = "关闭操作"; settle(graph, h)
            try button("More actions", graph).accessibilityActions.activate?(); settle(graph, h)
            #expect(try close(h, graph).accessibility?.label == "关闭操作")
            h.closeLabel = "Dismiss actions"; settle(graph, h)
            #expect(try close(h, graph).accessibility?.label == "Dismiss actions")
            #expect(try close(h, graph).accessibility?.help == "Dismiss actions")
            try close(h, graph).accessibilityActions.activate?(); settle(graph, h)
            #expect(!h.open)
        }
    }
}
