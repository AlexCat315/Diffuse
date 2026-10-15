import Foundation
import Testing
import EngineKernel
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Adaptive toolbar commands", .serialized)
struct ToolbarOverflowTests: GuavaUIComposeSerializedSuite {
    private final class Harness: View {
        @State var width: Float = 1280
        @State var input: UIEnvironment.Input = [.pointer, .keyboard]
        @State var scale: Float = 1
        @State var enabled = true
        @State var calls = 0
        @State var forcedOverflow = true
        @State var allPrimary = false
        @State var dark = false
        var body: some View {
            var environment = UIEnvironment()
            environment.viewport.width = width
            environment.input = input
            return LayerRoot {
                Toolbar(items: [
                    ToolbarItem(MenuItem(id: "run", title: "Run") { self.calls += 1 }, placement: .always),
                    ToolbarItem(MenuItem(id: "save", title: "Save workspace") { self.calls += 10 }, placement: allPrimary ? .always : .automatic(priority: 10)),
                    ToolbarItem(MenuItem(id: "export", title: "Export selection") { self.calls += 100 }, placement: allPrimary ? .always : .automatic()),
                    ToolbarItem(MenuItem(id: "share", title: "Share project") { self.calls += 1000 }, placement: allPrimary ? .always : .automatic()),
                    ToolbarItem(MenuItem(id: "disabled", title: "Unavailable", isEnabled: false) { self.calls += 10000 }, placement: allPrimary ? .always : forcedOverflow ? .overflow : .automatic()),
                    ToolbarItem(MenuItem(id: "settings", title: "Settings", isSelected: true) { self.calls += 100000 }, placement: allPrimary ? .always : forcedOverflow ? .overflow : .automatic())
                ], configure: { $0.isEnabled = self.enabled })
            }.frame(width: width, height: 300).surfaceEnvironment(environment).textScaler(.init(scale))
                .appearance(dark ? .dark : .light).reducedMotion()
        }
    }
    private func all(_ node: Node?) -> [Node] {
        guard let node else { return [] }; return [node] + node.children.flatMap { all($0) }
    }
    private func button(_ title: String, graph: ViewGraph) throws -> Node {
        try #require(all(graph.tree.root).first { $0.accessibility?.label == title && $0.attachments[ButtonHost.markerKey] != nil },
            "Missing \(title); buttons: \(all(graph.tree.root).filter { $0.attachments[ButtonHost.markerKey] != nil }.map { $0.accessibility?.label ?? "nil" })")
    }
    private func settle(_ graph: ViewGraph, harness: Harness) {
        for _ in 0..<8 { graph.recomposer.commitAll(); graph.computeLayout(width: harness.width, height: 300) }
    }
    private func scene(_ work: (Harness, ViewGraph, PlatformInputContext, PortalStore, EventDispatcher) throws -> Void) rethrows {
        try GlobalTestLock.locked {
            let prior = TextEnvironmentHolder.current
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = prior }
            let context = PlatformInputContext(), portals = PortalStore(), scheduler = AnimatorScheduler()
            context.addScopedAmbient(PortalStoreAmbient(portals))
            try context.withCurrent { try AnimatorScheduler.$current.withValue(scheduler) {
                let harness = Harness(), graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                let input = EventDispatcher(tree: graph.tree, interactions: context.interactions,
                    capture: context.pointerCapture, focusChain: context.focusChain)
                graph.install(root: harness); settle(graph, harness: harness)
                defer { graph.install(root: EmptyView()); scheduler.reset() }
                try work(harness, graph, context, portals, input)
            } }
        }
    }

    @Test("Natural sizes drive priority overflow, with retained commands and complete touch targets",
          arguments: [Float(390), 720, 1280], [Float(1), 2])
    func density(width: Float, scale: Float) throws {
        try scene { harness, graph, _, _, _ in
            let primary = try button("Run", graph: graph)
            let save = try button("Save workspace", graph: graph)
            for input: UIEnvironment.Input in [[.touch], [.touch, .pointer, .keyboard], [.pointer, .keyboard]] {
              for dark in [false, true] {
                harness.width = width; harness.scale = scale; harness.input = input
                harness.dark = dark
                settle(graph, harness: harness)
                #expect(primary === (try button("Run", graph: graph)))
                #expect(save === (try button("Save workspace", graph: graph)))
                #expect(primary.acceptsSubtreeInput)
                let visible = all(graph.tree.root).filter { $0.attachments[ButtonHost.markerKey] != nil && $0.acceptsSubtreeInput }
                #expect(visible.count >= 2)
                for control in visible {
                    #expect(control.absoluteFrame.minX >= 0 && control.absoluteFrame.maxX <= CGFloat(width) + 1)
                    if input.contains(.touch) { #expect(control.frame.width >= 44 && control.frame.height >= 44) }
                }
                let share = try button("Share project", graph: graph)
                if share.acceptsSubtreeInput { #expect(save.acceptsSubtreeInput) }
                if width == 390 { #expect(!share.acceptsSubtreeInput) }
                #expect(!graph.recomposer.hasPending)
              }
            }
        }
    }

    @Test("Keyboard overflow shares action/state, skips disabled commands and restores its trigger")
    func menuKeyboard() throws {
        try scene { harness, graph, context, portals, input in
            harness.width = 390; settle(graph, harness: harness)
            let more = try button("More actions", graph: graph)
            context.focusChain.focus(more)
            input.dispatch(.keyDown(KeyEvent(scancode: Scancode.space, keycode: 0, modifiers: [], isRepeat: false)))
            settle(graph, harness: harness)
            #expect(portals.entries.count == 1)
            #expect(more.accessibility?.state.isExpanded == true)
            let rows = all(graph.tree.root).filter { $0.attachments["__menu_item_id"] != nil }
            #expect(rows.contains { $0.accessibility?.label == "Settings" && $0.accessibility?.state.isSelected == true })
            let disabled = try #require(rows.first { $0.accessibility?.label == "Unavailable" })
            #expect(disabled.accessibilityActions.activate == nil)
            input.dispatch(.keyDown(KeyEvent(scancode: Scancode.end, keycode: 0, modifiers: [], isRepeat: false)))
            settle(graph, harness: harness)
            #expect(context.focusChain.focused?.accessibility?.label == "Settings")
            input.dispatch(.keyDown(KeyEvent(scancode: Scancode.return, keycode: 0, modifiers: [], isRepeat: false)))
            settle(graph, harness: harness)
            #expect(harness.calls == 100000 && portals.entries.isEmpty)
            #expect(context.focusChain.focused === more)
        }
    }

    @Test("Resize transfers hidden focus; disable and unmount close the menu and release input")
    func lifecycle() throws {
        try scene { harness, graph, context, portals, input in
            let share = try button("Share project", graph: graph)
            context.focusChain.focus(share)
            harness.width = 180; settle(graph, harness: harness)
            let more = try button("More actions", graph: graph)
            #expect(!share.acceptsSubtreeInput && context.focusChain.focused === more)
            let semanticNodes = AccessibilityTree.snapshot(root: graph.tree.root!).flatMap(flatten)
            #expect(!semanticNodes.contains { $0.node === share })
            let event = MouseButtonEvent(button: .left, x: Float(more.absoluteFrame.midX), y: Float(more.absoluteFrame.midY), clicks: 1)
            input.dispatch(.mouseButtonDown(event)); input.dispatch(.mouseButtonUp(event))
            settle(graph, harness: harness); #expect(portals.entries.count == 1)
            harness.enabled = false; settle(graph, harness: harness)
            #expect(portals.entries.isEmpty && context.pointerCapture.target == nil)
            #expect(context.focusChain.focused == nil)
            harness.enabled = true; harness.width = 1280; settle(graph, harness: harness)
            #expect(portals.entries.isEmpty && share.acceptsSubtreeInput)
            #expect(share === (try button("Share project", graph: graph)))
            more.accessibilityActions.activate?(); settle(graph, harness: harness)
            #expect(portals.entries.count == 1)
            graph.install(root: EmptyView()); graph.recomposer.commitAll()
            #expect(portals.entries.isEmpty && context.focusChain.focused == nil)
        }
    }
    private func flatten(_ element: AccessibilityElement) -> [AccessibilityElement] {
        [element] + element.children.flatMap(flatten)
    }

    @Test("Removing the last overflow closes its menu and returns keyboard focus to the bar")
    func noOverflow() throws {
        try scene { harness, graph, context, portals, _ in
            let more = try button("More actions", graph: graph)
            context.focusChain.focus(more)
            more.accessibilityActions.activate?(); settle(graph, harness: harness)
            #expect(portals.entries.count == 1)
            harness.forcedOverflow = false; settle(graph, harness: harness)
            #expect(portals.entries.isEmpty && !more.acceptsSubtreeInput)
            #expect(context.focusChain.focused === (try button("Run", graph: graph)))
            #expect(all(graph.tree.root).filter { $0.attachments[ButtonHost.markerKey] != nil && $0.acceptsSubtreeInput && $0.isFocusable }.count == 5)
        }
    }

    @Test("Pinned commands retain their natural size and keyboard navigation reveals the offscreen target")
    func primaryScroll() throws {
        try scene { harness, graph, context, portals, input in
            harness.width = 180; harness.input = [.touch, .keyboard]; harness.allPrimary = true
            settle(graph, harness: harness)
            let primary = try button("Run", graph: graph)
            let last = try button("Settings", graph: graph)
            #expect(primary.frame.width >= 44 && last.absoluteFrame.maxX > 180)
            #expect(!(try button("More actions", graph: graph)).acceptsSubtreeInput)
            context.focusChain.focus(primary)
            input.dispatch(.keyDown(KeyEvent(scancode: Scancode.end, keycode: 0, modifiers: [], isRepeat: false)))
            settle(graph, harness: harness)
            #expect(context.focusChain.focused === last)
            #expect(last.absoluteFrame.minX >= 0 && last.absoluteFrame.maxX <= 180)
            #expect(portals.entries.isEmpty)
        }
    }

    @Test("Icon commands keep their complete accessible title and activate from the touch hit area")
    func iconCommand() throws {
        try scene { harness, graph, _, _, input in
            var environment = UIEnvironment(); environment.input = [.touch]
            graph.install(root: Toolbar(items: [
                ToolbarItem(MenuItem(id: "run", title: "Run the project") { harness.calls += 1 },
                            icon: .texture(123), placement: .always)
            ]).frame(width: 390).surfaceEnvironment(environment))
            settle(graph, harness: harness)
            let control = try button("Run the project", graph: graph)
            #expect(control.frame.width >= 44 && control.frame.height >= 44)
            #expect(control.accessibility?.help == "Run the project")
            let point = MouseButtonEvent(button: .left, x: Float(control.absoluteFrame.minX + 2),
                y: Float(control.absoluteFrame.minY + 2), clicks: 1)
            input.dispatch(.mouseButtonDown(point)); input.dispatch(.mouseButtonUp(point))
            #expect(harness.calls == 1)
        }
    }
}
