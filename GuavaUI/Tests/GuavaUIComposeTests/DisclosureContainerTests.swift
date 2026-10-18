import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

private struct AccordionScene: View {
    @State var expanded: Set<String> = ["first"]
    var body: some View {
        Accordion([
            AccordionItem("first", "Project preferences with a wrapping title") {
                TextField(text: .constant("Draft")).debugName("accordion-draft")
            },
            AccordionItem("disabled", "Unavailable", isEnabled: false) { EmptyView() },
            AccordionItem("second", "Activity") { Text("Recent changes") }
        ], expanded: $expanded)
    }
}

@Suite("Adaptive disclosure containers", .serialized)
struct DisclosureContainerTests: GuavaUIComposeSerializedSuite {
    private func fixture(_ work: (ViewGraph, PlatformInputContext, AnimatorScheduler) throws -> Void) rethrows {
        try GlobalTestLock.locked {
            let previous = TextEnvironmentHolder.current
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make(size: 14, lineHeight: 20)
            defer { TextEnvironmentHolder.current = previous }
            let context = PlatformInputContext(), scheduler = AnimatorScheduler()
            try context.withCurrent {
                try AnimatorScheduler.$current.withValue(scheduler) {
                    let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                    defer { graph.install(root: EmptyView()) }
                    try work(graph, context, scheduler)
                }
            }
        }
    }
    private func all(_ node: Node) -> [Node] { [node] + node.children.flatMap(all) }
    private func settle(_ graph: ViewGraph, width: Float = 340) {
        for _ in 0..<4 { graph.recomposer.commitAll(); graph.computeLayout(width: width, height: 700) }
    }

    @Test("Accordion keeps scaled titles single-line, preserves expansion semantics and skips disabled headers")
    func accordionKeyboardAndSemantics() throws {
        try fixture { graph, context, scheduler in
            let scene = AccordionScene()
            graph.install(root: scene.frame(width: 340).theme(.defaultLight).textScaler(.init(2)))
            settle(graph)
            let headers = all(graph.tree.root!).filter { $0.accessibility?.role == .button && $0.accessibility?.state.isExpanded != nil }
            #expect(headers.count == 3)
            let first = try #require(headers.first), last = try #require(headers.last)
            #expect(first.frame.height == 64)
            #expect(headers[1].isFocusable == false)
            context.focusChain.focus(first); settle(graph)
            #expect(first.accessibility?.state.isExpanded == true)
            let dispatcher = EventDispatcher(tree: graph.tree, interactions: context.interactions,
                capture: context.pointerCapture, focusChain: context.focusChain)
            dispatcher.dispatch(.keyDown(KeyEvent(scancode: Scancode.arrowDown, keycode: 0, modifiers: [], isRepeat: false)))
            settle(graph)
            #expect(context.focusChain.focused === last && scene.expanded == ["first"])
            dispatcher.dispatch(.keyDown(KeyEvent(scancode: Scancode.return, keycode: 0, modifiers: [], isRepeat: false)))
            settle(graph); scheduler.tick(deltaTime: 1); settle(graph)
            #expect(scene.expanded == ["second"])
            #expect(first.accessibility?.state.isExpanded == false && last.accessibility?.state.isExpanded == true)
            #expect(!graph.layoutSnapshot().contains { $0.debugName == "accordion-draft" })
        }
    }

    @Test("Closing a section clears focused editing immediately, while exit paint is still mounted")
    func closingFocusedContent() throws {
        try fixture { graph, context, scheduler in
            let scene = AccordionScene()
            graph.install(root: scene.theme(.defaultLight)); settle(graph)
            let input = try #require(all(graph.tree.root!).first { $0.accessibility?.role == .textField })
            context.focusChain.focus(input)
            scene.$expanded.wrappedValue = []
            settle(graph)
            #expect(context.focusChain.focused == nil && !input.acceptsSubtreeInput)
            #expect(all(graph.tree.root!).contains { $0 === input })
            scheduler.tick(deltaTime: 1); settle(graph)
            #expect(!all(graph.tree.root!).contains { $0 === input })
        }
    }

    @Test("Disclosure and Panel headers fit one scaled title line and preserve accessories")
    func headerGeometry() throws {
        try fixture { graph, _, _ in
            graph.install(root: Box(direction: .column, alignItems: .stretch) {
                DisclosureGroup("A long disclosure heading that wraps", isExpanded: .constant(false)) { EmptyView() }
                Panel("Inspector", accessory: {
                    Button(icon: .resource(UIIcons.Action.settings), tooltip: "Settings") {}.debugName("panel-action")
                }) { Text("Content") }.frame(height: 220)
            }.theme(.defaultLight).textScaler(.init(2)))
            settle(graph)
            let label = try #require(graph.layoutSnapshot().first { $0.debugName == "disclosure-label" }?.absoluteFrame)
            let header = try #require(graph.layoutSnapshot().first { $0.debugName == "disclosure-header" }?.absoluteFrame)
            #expect(label.height == 36 && header.contains(label))
            let title = try #require(all(graph.tree.root!).first { $0.layoutNode?.textInputs?.text == "Inspector" })
            let action = try #require(graph.layoutSnapshot().first { $0.debugName == "panel-action" }?.absoluteFrame)
            #expect(title.frame.height == 36 && action.height == 46)
            #expect(abs(action.midY - title.absoluteFrame.midY) < 1)
        }
    }

    @Test("Tree virtualization, row hit regions and disclosure slots share the same scaled geometry")
    func treeGeometry() throws {
        try fixture { graph, context, _ in
            var selected: Int?
            graph.install(root: Tree([0], id: \.self, children: { $0 == 0 ? [1, 2] : [] }, configure: {
                $0.selection.expanded = .constant([0])
                $0.selection.primary = Binding(get: { selected }, set: { selected = $0 })
            }) { value, _, _, _ in Text("Node \(value)").font(.body).debugName("tree-text-\(value)") }
                .theme(.defaultLight).textScaler(.init(2)))
            settle(graph)
            let rows = all(graph.tree.root!).filter { $0.accessibility?.role == .treeItem }
            #expect(rows.count == 3 && rows.allSatisfy { $0.frame.height == 60 })
            let rootText = try #require(graph.layoutSnapshot().first { $0.debugName == "tree-text-0" }?.absoluteFrame)
            let childText = try #require(graph.layoutSnapshot().first { $0.debugName == "tree-text-1" }?.absoluteFrame)
            #expect(rootText.height == 40 && childText.minY - rootText.minY == 60)
            #expect(childText.minX - rootText.minX == 32)
            #expect(all(graph.tree.root!).contains { $0.viewTag?.contains("Image") == true && $0.frame.width == 24 })
            let dispatcher = EventDispatcher(tree: graph.tree, interactions: context.interactions,
                capture: context.pointerCapture, focusChain: context.focusChain)
            let click = MouseButtonEvent(button: .left, x: Float(childText.midX), y: Float(childText.midY), clicks: 1)
            dispatcher.dispatch(.mouseButtonDown(click)); dispatcher.dispatch(.mouseButtonUp(click))
            #expect(selected == 1)
        }
    }
}
