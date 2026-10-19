import Foundation
import GuavaUIAgent
import GuavaUIRuntime
import Testing

@testable import GuavaUICompose

@Suite("Navigation drawer", .serialized)
@MainActor
struct NavigationDrawerTests: GuavaUIComposeSerializedSuite {
    private struct Header: View {
        @State private var text: TextBuffer = "Private navigation note"
        var body: some View { TextField("Navigation note", text: $text).padding(12) }
    }
    private final class Harness: View {
        @State var width: Float = 390
        @State var height: Float = 640
        @State var open = false
        @State var selection: Int? = 29
        @State var scale: Float = 1
        @State var dark = false
        @State var input: UIEnvironment.Input = [.pointer, .keyboard]
        @State var reduced = true
        @State var closesOnSelection = true
        @State var closesOnEscape = true
        @State var closesOnBackdrop = true
        @State var swipe = true
        @State var backgroundCalls = 0
        var body: some View {
            var surface = UIEnvironment()
            surface.viewport.width = 1280  // Fitting must use the actual host bounds.
            surface.input = input
            return LayerRoot {
                Button("Open navigation") { self.open = true }.accessibilityLabel("Open navigation")
                Button("Background action") { self.backgroundCalls += 1 }.accessibilityLabel("Background action")
                NavigationDrawer(
                    "Workspace navigation", isPresented: $open, selection: $selection,
                    sections: [
                        SidebarSection(
                            "workspace", title: "Destinations",
                            items: (0..<30).map { index in
                                SidebarItem(index, "Destination \(index)") { $0.isEnabled = index != 2 }
                            })
                    ],
                    configure: {
                        $0.closesOnSelection = closesOnSelection
                        $0.dismissal.closesOnEscape = closesOnEscape
                        $0.dismissal.closesOnBackdrop = closesOnBackdrop
                        $0.allowsSwipeDismissal = swipe
                    }, header: { Header() }, footer: { Text("Navigation footer").padding(12) })
            }.surfaceEnvironment(surface).textScaler(.init(scale))
                .appearance(dark ? .dark : .light).reducedMotion(reduced)
        }
    }
    private func nodes(_ node: Node?) -> [Node] {
        guard let node else { return [] }
        return [node] + node.children.flatMap { nodes($0) }
    }
    private func row(_ id: Int, _ graph: ViewGraph) throws -> Node {
        try #require(
            nodes(graph.tree.root).first {
                $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == "sidebar-item-\(id)"
            })
    }
    private func control(_ title: String, _ graph: ViewGraph) throws -> Node {
        try #require(nodes(graph.tree.root).first { $0.accessibility?.label == title && $0.isFocusable })
    }
    private func panel(_ graph: ViewGraph) throws -> Node {
        try #require(nodes(graph.tree.root).first { $0.accessibility?.role == .dialog })
    }
    private func settle(_ graph: ViewGraph, _ harness: Harness) {
        for _ in 0..<8 {
            graph.recomposer.commitAll()
            graph.computeLayout(width: harness.width, height: harness.height)
        }
    }
    private func scene(
        _ work: (Harness, ViewGraph, PlatformInputContext, PortalStore, AnimatorScheduler, EventDispatcher) throws ->
            Void
    ) rethrows {
        try GlobalTestLock.locked {
            let previous = TextEnvironmentHolder.current
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = previous }
            let context = PlatformInputContext()
            let portals = PortalStore()
            let scheduler = AnimatorScheduler()
            context.addScopedAmbient(PortalStoreAmbient(portals))
            try context.withCurrent {
                try AnimatorScheduler.$current.withValue(scheduler) {
                    let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                    let harness = Harness()
                    let input = EventDispatcher(
                        tree: graph.tree, interactions: context.interactions,
                        capture: context.pointerCapture, focusChain: context.focusChain)
                    graph.install(root: harness)
                    settle(graph, harness)
                    defer {
                        graph.install(root: EmptyView())
                        scheduler.reset()
                    }
                    try work(harness, graph, context, portals, scheduler, input)
                }
            }
        }
    }
    private func key(_ code: UInt32, _ input: EventDispatcher, modifiers: KeyModifiers = []) {
        input.dispatch(.keyDown(KeyEvent(scancode: code, keycode: 0, modifiers: modifiers, isRepeat: false)))
    }
    private func click(_ frame: CGRect, _ input: EventDispatcher, button: MouseButton = .left) {
        let event = MouseButtonEvent(button: button, x: Float(frame.midX), y: Float(frame.midY), clicks: 1)
        input.dispatch(.mouseButtonDown(event))
        input.dispatch(.mouseButtonUp(event))
    }

    @Test(
        "Actual host bounds fit the drawer during rotation; selected rows, drafts and identity survive theme and density changes"
    )
    func fittingAndRetention() throws {
        try scene { harness, graph, context, _, _, input in
            harness.open = true
            settle(graph, harness)
            let original = try panel(graph)
            let note = try control("Navigation note", graph)
            context.focusChain.focus(note)
            input.dispatch(.textInput("Edited "))
            settle(graph, harness)
            let draft = note.resolvedAccessibilityValue
            #expect(draft.contains("Edited "))
            let diagnostics = UIDiagnostics(tree: graph.tree, state: graph.stateRegistry)
            for scale: Float in [1, 2] {
                for capabilities: UIEnvironment.Input in [
                    [.pointer, .keyboard], [.touch], [.touch, .pointer, .keyboard],
                ] {
                    for dark in [false, true] {
                        for width: Float in [280, 390, 720, 1280, 390] {
                            harness.width = width
                            harness.scale = scale
                            harness.input = capabilities
                            harness.dark = dark
                            settle(graph, harness)
                            let current = try panel(graph)
                            #expect(current.id == original.id && current.accessibility?.label == "Workspace navigation")
                            #expect(
                                current.absoluteFrame
                                    == CGRect(x: 0, y: 0, width: CGFloat(min(320, width - 56)), height: 640))
                            #expect(harness.open && harness.selection == 29)
                            #expect(note.id == (try control("Navigation note", graph)).id)
                            #expect(note.resolvedAccessibilityValue == draft)
                            #expect(context.focusChain.focused?.id == note.id)
                            #expect((try row(29, graph)).frame.height >= 44)
                            #expect((try control("Collapse navigation", graph)).frame.height >= 44)
                            let selected = try diagnostics.queryNodes(
                                text: "Destination 29", role: "button", visibleOnly: true)
                            // Editing a header must not continuously pull the scroll viewport back to selection.
                            #expect(selected.total <= 1)
                            #expect(!graph.recomposer.hasPending)
                        }
                    }
                }
            }
        }
    }

    @Test(
        "Keyboard focus is trapped; navigation skips disabled rows, selection reveals, activation closes and restores the trigger"
    )
    func keyboardAndSelection() throws {
        try scene { harness, graph, context, portals, _, input in
            let opener = try control("Open navigation", graph)
            context.focusChain.focus(opener)
            key(Scancode.space, input)
            settle(graph, harness)
            let dialog = try panel(graph)
            #expect(
                context.focusChain.hasModalScope && context.focusChain.contains(context.focusChain.focused!, in: dialog)
            )
            for _ in 0..<8 {
                key(Scancode.tab, input)
                settle(graph, harness)
                #expect(context.focusChain.contains(context.focusChain.focused!, in: dialog))
            }
            let selected = try row(29, graph)
            context.focusChain.focus(selected)
            key(Scancode.home, input)
            settle(graph, harness)
            #expect(harness.selection == 0 && harness.open)
            key(Scancode.arrowDown, input)
            key(Scancode.arrowDown, input)
            settle(graph, harness)
            #expect(harness.selection == 3 && harness.open)
            key(Scancode.end, input)
            settle(graph, harness)
            let visible = try UIDiagnostics(tree: graph.tree).queryNodes(
                text: "Destination 29", role: "button", visibleOnly: true)
            #expect(visible.total == 1)
            key(Scancode.return, input)
            settle(graph, harness)
            #expect(!harness.open && portals.entries.isEmpty && !context.focusChain.hasModalScope)
            #expect(context.focusChain.focused?.id == opener.id)
            #expect(harness.selection == 29)
        }
    }

    @Test("Backdrop, Escape, explicit close and activation policies remain independent; background input is blocked")
    func dismissalPolicies() throws {
        try scene { harness, graph, context, portals, _, input in
            harness.open = true
            harness.closesOnBackdrop = false
            harness.closesOnEscape = false
            harness.closesOnSelection = false
            harness.selection = 0
            settle(graph, harness)
            click(CGRect(x: 350, y: 300, width: 20, height: 20), input)
            key(Scancode.escape, input)
            settle(graph, harness)
            #expect(harness.open && harness.backgroundCalls == 0)
            let destination = try row(0, graph)
            click(destination.absoluteFrame, input)
            settle(graph, harness)
            #expect(harness.open && harness.selection == 0)
            harness.closesOnBackdrop = true
            settle(graph, harness)
            click(CGRect(x: 350, y: 300, width: 20, height: 20), input, button: .right)
            settle(graph, harness)
            #expect(harness.open)
            click(CGRect(x: 350, y: 300, width: 20, height: 20), input)
            settle(graph, harness)
            #expect(!harness.open && portals.entries.isEmpty)
            harness.open = true
            harness.closesOnEscape = true
            settle(graph, harness)
            key(Scancode.escape, input)
            settle(graph, harness)
            #expect(!harness.open && !context.focusChain.hasModalScope)
            harness.open = true
            settle(graph, harness)
            click(try control("Collapse navigation", graph).absoluteFrame, input)
            settle(graph, harness)
            #expect(!harness.open && portals.entries.isEmpty)
        }
    }

    @Test("Pointer opening does not show an automatic tooltip; the collapse toggle and modal scrim retain their semantics")
    func pointerPresentation() throws {
        try scene { h, graph, context, portals, scheduler, input in
            let opener = try control("Open navigation", graph)
            click(opener.absoluteFrame, input); settle(graph, h)
            #expect(!context.focusChain.isFocusVisible)
            scheduler.tick(deltaTime: 1); settle(graph, h)
            #expect(portals.entries.count == 1)
            let toggle = try control("Collapse navigation", graph)
            #expect(toggle.accessibility?.state.isExpanded == true)
            let backdrop = try #require(nodes(graph.tree.root).first {
                context.interactions.handlers(for: $0).pointerRoute?.debugName == "modal.backdrop"
            })
            #expect(backdrop.backgroundColor == backdrop.theme.colors.overlay)
            click(toggle.absoluteFrame, input); settle(graph, h)
            #expect(!h.open && context.focusChain.focused === opener && !context.focusChain.isFocusVisible)
        }
    }

    @Test(
        "A left swipe cancels a destination press without selecting it; vertical, short and disabled swipes do not dismiss"
    )
    func swipeDismissal() throws {
        try scene { harness, graph, context, portals, _, input in
            harness.open = true
            harness.selection = 0
            settle(graph, harness)
            @MainActor func swipe(dx: Float, dy: Float) throws {
                let row = try row(1, graph)
                let point = row.absoluteFrame
                let start = MouseButtonEvent(button: .left, x: Float(point.midX), y: Float(point.midY), clicks: 1)
                input.dispatch(.mouseButtonDown(start))
                input.dispatch(.mouseMotion(MouseMotionEvent(x: start.x + dx, y: start.y + dy, deltaX: dx, deltaY: dy)))
                input.dispatch(
                    .mouseButtonUp(MouseButtonEvent(button: .left, x: start.x + dx, y: start.y + dy, clicks: 1)))
                settle(graph, harness)
            }
            try swipe(dx: -20, dy: 0)
            #expect(harness.open && harness.selection == 0)
            try swipe(dx: 0, dy: 60)
            #expect(harness.open)
            harness.swipe = false
            settle(graph, harness)
            try swipe(dx: -400, dy: 0)
            #expect(harness.open)
            harness.swipe = true
            settle(graph, harness)
            try swipe(dx: -120, dy: 0)
            #expect(!harness.open && harness.selection == 0 && portals.entries.isEmpty)
            #expect(context.pointerCapture.target == nil)
        }
    }

    @Test("Motion slides from the leading edge, reverses in place and unmount releases the scope and capture")
    func animationLifecycle() throws {
        try scene { harness, graph, context, portals, scheduler, input in
            harness.reduced = false
            settle(graph, harness)
            harness.open = true
            settle(graph, harness)
            let dialog = try panel(graph)
            #expect(dialog.absoluteFrame.maxX <= 0.5)
            scheduler.tick(deltaTime: 1)
            settle(graph, harness)
            #expect(dialog.absoluteFrame.minX == 0)
            harness.open = false
            settle(graph, harness)
            #expect(!dialog.acceptsSubtreeInput)
            scheduler.tick(deltaTime: 0.05)
            settle(graph, harness)
            #expect(dialog.absoluteFrame.minX < 0)
            harness.open = true
            settle(graph, harness)
            scheduler.tick(deltaTime: 1)
            settle(graph, harness)
            #expect((try panel(graph)).id == dialog.id)
            let close = try control("Collapse navigation", graph)
            let event = MouseButtonEvent(
                button: .left, x: Float(close.absoluteFrame.midX), y: Float(close.absoluteFrame.midY), clicks: 1)
            input.dispatch(.mouseButtonDown(event))
            #expect(context.pointerCapture.target != nil)
            graph.install(root: EmptyView())
            graph.recomposer.commitAll()
            #expect(
                portals.entries.isEmpty && !context.focusChain.hasModalScope && context.pointerCapture.target == nil)
        }
    }

    @Test("AI diagnostics distinguish a visible modal from its blocked background")
    func diagnosticModalInput() throws {
        try scene { harness, graph, _, _, _, _ in
            let diagnostics = UIDiagnostics(tree: graph.tree)
            let before = try diagnostics.queryNodes(text: "Background action", role: "button")
            #expect(before.items.first?.presentation.inputEnabled == true)
            harness.open = true
            settle(graph, harness)
            let modal = try diagnostics.queryNodes(text: "Workspace navigation", role: "dialog", visibleOnly: true)
            let background = try diagnostics.queryNodes(text: "Background action", role: "button")
            #expect(modal.total == 1)
            #expect(background.items.first?.presentation.inputEnabled == false)
        }
    }

    @Test("Validated AI tools find the real drawer between host frames and exclude its blocked background")
    func validatedModalTools() async throws {
        let prepared = GlobalTestLock.locked {
            let previous = TextEnvironmentHolder.current
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = previous }
            let context = PlatformInputContext()
            let portals = PortalStore()
            let scheduler = AnimatorScheduler()
            context.addScopedAmbient(PortalStoreAmbient(portals))
            return context.withCurrent {
                AnimatorScheduler.$current.withValue(scheduler) {
                    let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                    let harness = Harness()
                    graph.install(root: harness)
                    settle(graph, harness)
                    harness.open = true
                    settle(graph, harness)
                    return (graph, context, scheduler)
                }
            }
        }
        let (graph, context, scheduler) = prepared
        defer {
            GlobalTestLock.locked {
                context.withCurrent {
                    graph.install(root: EmptyView())
                    scheduler.reset()
                }
            }
        }
        let diagnostics = UIDiagnostics(tree: graph.tree, state: graph.stateRegistry)
        let toolbox = try diagnostics.toolbox()
        for (text, role, expected) in [
            ("Workspace navigation", "dialog", 1), ("Collapse navigation", "button", 1),
            ("Background action", "button", 0),
        ] {
            let input = try JSONSerialization.data(withJSONObject: [
                "text": text, "role": role, "input_enabled_only": true,
            ])
            let result = try await toolbox.execute(name: "query_ui_nodes", input: input)
            let response = try #require(JSONSerialization.jsonObject(with: result.json) as? [String: Any])
            let data = try #require(response["data"] as? [String: Any])
            #expect(data["total"] as? Int == expected)
            #expect(!String(decoding: result.json, as: UTF8.self).contains("Private navigation note"))
        }
    }
}
