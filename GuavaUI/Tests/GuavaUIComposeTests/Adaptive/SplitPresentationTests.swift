import Foundation
import GuavaUIAgent
import GuavaUIRuntime
import Testing

@testable import GuavaUICompose

@Suite("Adaptive split presentation", .serialized)
@MainActor
struct SplitPresentationTests: GuavaUIComposeSerializedSuite {
    private struct Pane: View {
        let name: String
        @State private var draft: TextBuffer = "Private draft"
        @State private var count = 0
        var body: some View {
            Box(direction: .column, alignItems: .stretch, spacing: 8) {
                TextField("\(name) draft", text: $draft).debugName("field-\(name)")
                Button("\(name) visits: \(count)") { count += 1 }.debugName("counter-\(name)")
                ScrollView(.vertical) {
                    Box(direction: .column, alignItems: .stretch) {
                        Text("\(name) scroll content").frame(height: 1000)
                    }.flex(0, shrink: 0)
                }.flex(1, shrink: 1, basis: 0).debugName("scroll-\(name)")
            }.debugName("pane-\(name)")
        }
    }
    private final class Harness: View {
        let axis: SplitAxis
        let externalSelection: Bool
        @State var width: Float = 720
        @State var height: Float = 400
        @State var threshold: Float = 600
        @State var fraction: Float = 0.35
        @State var pane: SplitPane = .first
        @State var scale: Float = 1
        @State var dark = false
        @State var longTitles = false
        @State var input: UIEnvironment.Input = [.pointer, .keyboard]
        init(axis: SplitAxis = .horizontal, externalSelection: Bool = true) {
            self.axis = axis
            self.externalSelection = externalSelection
        }
        var body: some View {
            var surface = UIEnvironment()
            surface.viewport.width = 1280
            surface.input = input
            return SplitView(
                axis, fraction: $fraction, spacing: 3,
                constraints: .init(minimumFirst: 150, minimumSecond: 220),
                compact: .init(
                    firstTitle: longTitles ? "项目导航与层级结构" : "Navigation",
                    secondTitle: longTitles ? "Inspector and document properties" : "Details"
                ) {
                    $0.threshold = threshold
                    if externalSelection { $0.selection = $pane }
                }
            ) {
                Pane(name: "First")
            } second: {
                Pane(name: "Second")
            }
            .frame(width: width, height: height).surfaceEnvironment(surface)
            .textScaler(.init(scale)).appearance(dark ? .dark : .light).reducedMotion()
        }
    }
    private func nodes(_ node: Node?) -> [Node] {
        guard let node else { return [] }
        return [node] + node.children.flatMap { nodes($0) }
    }
    private func named(_ name: String, in graph: ViewGraph) throws -> Node {
        try #require(
            nodes(graph.tree.root).first { $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == name })
    }
    private func tab(_ title: String, in graph: ViewGraph) throws -> Node {
        try #require(
            nodes(graph.tree.root).first { $0.accessibility?.role == .tab && $0.accessibility?.label == title })
    }
    private func handle(_ graph: ViewGraph) throws -> Node {
        try #require(nodes(graph.tree.root).first { $0.accessibility?.label == "Resize split" })
    }
    private func settle(_ graph: ViewGraph, _ harness: Harness) {
        for _ in 0..<8 {
            graph.recomposer.commitAll()
            graph.computeLayout(width: harness.width, height: harness.height)
        }
    }
    private func scene(
        axis: SplitAxis = .horizontal, externalSelection: Bool = true,
        _ work: (Harness, ViewGraph, PlatformInputContext, EventDispatcher) throws -> Void
    ) rethrows {
        try GlobalTestLock.locked {
            let previous = TextEnvironmentHolder.current
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = previous }
            let context = PlatformInputContext()
            let scheduler = AnimatorScheduler()
            try context.withCurrent {
                try AnimatorScheduler.$current.withValue(scheduler) {
                    let harness = Harness(axis: axis, externalSelection: externalSelection)
                    let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                    let input = EventDispatcher(
                        tree: graph.tree, interactions: context.interactions,
                        capture: context.pointerCapture, focusChain: context.focusChain)
                    graph.install(root: harness)
                    settle(graph, harness)
                    defer {
                        graph.install(root: EmptyView())
                        scheduler.reset()
                    }
                    try work(harness, graph, context, input)
                }
            }
        }
    }
    private func key(_ code: UInt32, _ input: EventDispatcher) {
        input.dispatch(.keyDown(KeyEvent(scancode: code, keycode: 0, modifiers: [], isRepeat: false)))
    }

    @Test("Allocated width chooses a retained pane across theme, input and 200 percent text")
    func geometryAndDiscovery() throws {
        try scene { harness, graph, _, _ in
            let first = try named("pane-First", in: graph)
            let second = try named("pane-Second", in: graph)
            let diagnostics = UIDiagnostics(tree: graph.tree, state: graph.stateRegistry)
            for scale: Float in [1, 2] {
                for capabilities: UIEnvironment.Input in [
                    [.pointer, .keyboard], [.touch], [.touch, .pointer, .keyboard],
                ] {
                    for dark in [false, true] {
                        for width: Float in [390, 720, 1280, 390] {
                            harness.width = width
                            harness.scale = scale
                            harness.input = capabilities
                            harness.dark = dark
                            settle(graph, harness)
                            #expect(try named("pane-First", in: graph).id == first.id)
                            #expect(try named("pane-Second", in: graph).id == second.id)
                            let divider = try handle(graph)
                            let navigation = try tab("Navigation", in: graph)
                            let compact = width < 600
                            #expect(first.acceptsSubtreeInput)
                            #expect(second.acceptsSubtreeInput == !compact)
                            #expect(divider.acceptsSubtreeInput == !compact)
                            #expect(navigation.acceptsSubtreeInput == compact)
                            #expect(first.absoluteFrame.minX >= 0 && first.absoluteFrame.maxX <= CGFloat(width))
                            if compact {
                                #expect(abs(first.frame.width - CGFloat(width)) < 1)
                                #expect(navigation.absoluteFrame.maxY <= first.absoluteFrame.minY)
                                for title in ["Navigation", "Details"] {
                                    let tab = try tab(title, in: graph)
                                    #expect(tab.absoluteFrame.minX >= 0 && tab.absoluteFrame.maxX <= CGFloat(width))
                                    if capabilities.contains(.touch) {
                                        #expect(tab.frame.height >= 44 && tab.frame.width >= 44)
                                    }
                                }
                            } else {
                                #expect(first.frame.width >= 149 && second.frame.width >= 219)
                                #expect(divider.frame.width >= (capabilities.contains(.touch) ? 44 : 7))
                            }
                            #expect(harness.fraction == 0.35)
                            let visibleSecond = try diagnostics.queryNodes(
                                text: "Second draft", role: "textField", visibleOnly: true)
                            #expect(visibleSecond.total == (compact ? 0 : 1))
                            let retained = try diagnostics.queryNodes(text: "Second draft", role: "textField")
                            #expect(retained.items.first?.presentation.inputEnabled == !compact)
                            #expect(!graph.recomposer.hasPending)
                        }
                    }
                }
            }
        }
    }

    @Test("Typing, local state and scroll survive pane switches; hidden focus and capture are transferred")
    func interactionAndRetention() throws {
        try scene { harness, graph, context, input in
            let secondField = try #require(
                nodes(try named("field-Second", in: graph)).first {
                    $0.accessibility?.role == .textField && $0.isFocusable
                })
            let secondCounter = try named("counter-Second", in: graph)
            let scroll = try named("scroll-Second", in: graph)
            secondCounter.accessibilityActions.activate?()
            context.focusChain.focus(secondField)
            input.dispatch(.textInput("Live "))
            settle(graph, harness)
            let draft = secondField.accessibilityValueProvider?.read() ?? secondField.accessibility?.value
            #expect(draft?.contains("Live ") == true)
            scroll.contentOffset.y = 180
            harness.width = 390
            settle(graph, harness)
            let navigation = try tab("Navigation", in: graph)
            let details = try tab("Details", in: graph)
            #expect(context.focusChain.focused?.id == navigation.id)
            #expect(!secondField.acceptsSubtreeInput && !secondCounter.acceptsSubtreeInput)
            func semanticIDs(_ element: AccessibilityElement) -> [ElementID] {
                [element.node.id] + element.children.flatMap(semanticIDs)
            }
            #expect(!AccessibilityTree.snapshot(root: graph.tree.root!).flatMap(semanticIDs).contains(secondField.id))
            #expect(scroll.contentOffset.y == 180)
            key(Scancode.end, input)
            settle(graph, harness)
            #expect(harness.pane == .second && context.focusChain.focused?.id == details.id)
            #expect(nodes(try named("field-Second", in: graph)).contains { $0.id == secondField.id })
            #expect((secondField.accessibilityValueProvider?.read() ?? secondField.accessibility?.value) == draft)
            #expect(AccessibilityTree.snapshot(root: secondCounter).first?.semantics.label == "Second visits: 1")
            #expect(scroll.contentOffset.y == 180)
            harness.width = 720
            settle(graph, harness)
            #expect(context.focusChain.focused?.id == secondField.id)
            let divider = try handle(graph)
            let event = MouseButtonEvent(
                button: .left, x: Float(divider.absoluteFrame.midX), y: Float(divider.absoluteFrame.midY), clicks: 1)
            input.dispatch(.mouseButtonDown(event))
            #expect(context.pointerCapture.target?.id == divider.id)
            input.dispatch(.mouseMotion(MouseMotionEvent(x: event.x + 30, y: event.y, deltaX: 30, deltaY: 0)))
            let expected: Float = 0.35 + 30 / (720 - 7 - 6)
            #expect(abs(harness.fraction - expected) < 0.0001)
            harness.width = 390
            settle(graph, harness)
            #expect(context.pointerCapture.target == nil)
            let fraction = harness.fraction
            divider.accessibilityActions.increment?()
            #expect(harness.fraction == fraction)
            let focusedID = context.focusChain.focused?.id
            context.focusChain.focus(divider)
            #expect(context.focusChain.focused?.id == focusedID)
            harness.width = 720
            settle(graph, harness)
            context.focusChain.focus(divider)
            key(Scancode.arrowRight, input)
            settle(graph, harness)
            #expect(harness.fraction > fraction)
            let firstField = try #require(nodes(try named("field-First", in: graph)).first {
                $0.accessibility?.role == .textField && $0.isFocusable
            })
            harness.pane = .first
            context.focusChain.focus(firstField)
            for width: Float in [390, 720, 390] {
                harness.width = width; settle(graph, harness)
                #expect(context.focusChain.focused?.id == firstField.id)
            }
            graph.install(root: EmptyView())
            graph.recomposer.commitAll()
            #expect(context.pointerCapture.target == nil && context.focusChain.focused == nil)
        }
    }

    @Test(
        "Vertical collapse measures the outer height without selector feedback; local selection persists and resets on removal"
    )
    func verticalAndLocalSelection() throws {
        try scene(axis: .vertical, externalSelection: false) { harness, graph, context, input in
            harness.threshold = 300
            harness.height = 299
            settle(graph, harness)
            let details = try tab("Details", in: graph)
            context.focusChain.focus(details)
            key(Scancode.space, input)
            settle(graph, harness)
            #expect((try named("pane-Second", in: graph)).acceptsSubtreeInput)
            for height: Float in [300, 299, 301, 299] {
                harness.height = height
                settle(graph, harness)
                #expect(details.acceptsSubtreeInput == (height < 300))
                #expect(details.accessibility?.state.isSelected == true)
                #expect(!graph.recomposer.hasPending)
            }
            graph.install(root: EmptyView())
            graph.recomposer.commitAll()
            graph.install(root: harness)
            settle(graph, harness)
            #expect((try tab("Navigation", in: graph)).accessibility?.state.isSelected == true)
        }
    }

    @Test("Long localized pane titles wrap at 200 percent and the touch target switches panes")
    func localizedTouchSelector() throws {
        try scene { harness, graph, _, input in
            harness.width = 390
            harness.scale = 2
            harness.input = [.touch]
            harness.longTitles = true
            settle(graph, harness)
            let title = "Inspector and document properties"
            let details = try tab(title, in: graph)
            let label = try #require(nodes(details).first { $0.layoutNode?.textInputs?.text == title })
            #expect(label.absoluteFrame.minX >= details.absoluteFrame.minX)
            #expect(label.absoluteFrame.maxX <= details.absoluteFrame.maxX)
            #expect(label.frame.width >= details.frame.width - 32)
            #expect(label.frame.height > 32)
            #expect(details.frame.height >= 44 && details.frame.width >= 44)
            let event = MouseButtonEvent(
                button: .left, x: Float(details.absoluteFrame.minX + 2),
                y: Float(details.absoluteFrame.minY + 2), clicks: 1)
            input.dispatch(.mouseButtonDown(event))
            input.dispatch(.mouseButtonUp(event))
            settle(graph, harness)
            #expect(harness.pane == .second)
            #expect((try named("pane-Second", in: graph)).acceptsSubtreeInput)
            #expect(!(try named("pane-First", in: graph)).acceptsSubtreeInput)
        }
    }

    @Test("Validated AI discovery excludes hidden split controls and reports retained nodes without reading drafts")
    func validatedDiscovery() async throws {
        let graph = GlobalTestLock.locked {
            let previous = TextEnvironmentHolder.current
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = previous }
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(
                root: SplitView(compact: .init(firstTitle: "Navigation", secondTitle: "Details")) {
                    TextField("First draft", text: .constant("Private first draft"))
                } second: {
                    TextField("Second draft", text: .constant("Private second draft"))
                }.frame(width: 390, height: 240))
            for _ in 0..<8 {
                graph.recomposer.commitAll()
                graph.computeLayout(width: 390, height: 240)
            }
            return graph
        }
        defer { GlobalTestLock.locked { graph.install(root: EmptyView()) } }
        let diagnostics = UIDiagnostics(tree: graph.tree, state: graph.stateRegistry)
        let toolbox = try diagnostics.toolbox()
        for (title, role, visible, expected) in [
            ("Navigation", "tab", true, 1), ("First draft", "textField", true, 1),
            ("Second draft", "textField", true, 0), ("Second draft", "textField", false, 1),
        ] {
            let input = try JSONSerialization.data(withJSONObject: [
                "text": title, "role": role, "visible_only": visible,
            ])
            let result = try await toolbox.execute(name: "query_ui_nodes", input: input)
            let response = try #require(JSONSerialization.jsonObject(with: result.json) as? [String: Any])
            let data = try #require(response["data"] as? [String: Any])
            #expect(data["total"] as? Int == expected)
            #expect(!String(decoding: result.json, as: UTF8.self).contains("Private"))
            if !visible {
                let items = try #require(data["items"] as? [[String: Any]])
                let presentation = try #require(items.first?["presentation"] as? [String: Any])
                #expect(presentation["isVisible"] as? Bool == false)
                #expect(presentation["inputEnabled"] as? Bool == false)
            }
        }
    }
}
