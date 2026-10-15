import Foundation
import GuavaUIAgent
import GuavaUIRuntime
import Testing

@testable import GuavaUICompose

@Suite("Adaptive field labels", .serialized)
@MainActor
struct FieldLayoutTests: GuavaUIComposeSerializedSuite {
    private final class Harness: View {
        let grid: Bool
        @State var width: Float = 720
        @State var scale: Float = 1
        @State var input: UIEnvironment.Input = [.pointer, .keyboard]
        @State var columns = 1
        @State var placement: FieldLabelPlacement = .adaptive
        @State var name: TextBuffer = "Draft"
        @State var email: TextBuffer = "hello@example.com"
        init(grid: Bool) { self.grid = grid }
        var body: some View {
            var surface = UIEnvironment()
            // Deliberately different from the content width: decisions belong
            // to the field's container, not the window's width class.
            surface.viewport.width = 1280
            surface.input = input
            return content.frame(width: width, height: 600)
                .surfaceEnvironment(surface).textScaler(.init(scale)).reducedMotion()
        }
        @ViewBuilder private var content: some View {
            if grid {
                PropertyGrid(
                    [
                        PropertyGridSection(
                            id: "identity", title: "Identity",
                            rows: [
                                PropertyGridRow(id: "name", label: "Display name") { TextField("Name", text: $name) },
                                PropertyGridRow(id: "email", label: "Email") { TextField("Email", text: $email) },
                            ], isCollapsible: true)
                    ], labelWidth: 220, minValueWidth: 220, labelPlacement: placement)
            } else {
                Form(
                    [
                        FormField("name", "Display name") { TextField("Name", text: $name) },
                        FormField("email", "Email") { TextField("Email", text: $email) },
                    ],
                    configure: {
                        $0.columns = columns
                        $0.labelWidth = 220
                        $0.minValueWidth = 220
                        $0.labelPlacement = placement
                    })
            }
        }
    }
    private func nodes(_ node: Node?) -> [Node] {
        guard let node else { return [] }
        return [node] + node.children.flatMap { nodes($0) }
    }
    private func label(_ graph: ViewGraph) throws -> Node {
        try #require(nodes(graph.tree.root).first { $0.layoutNode?.textInputs?.text == "Display name" })
    }
    private func fields(_ graph: ViewGraph) -> [Node] {
        nodes(graph.tree.root).filter { $0.accessibility?.role == .textField && $0.isFocusable }
    }
    private func settle(_ graph: ViewGraph, harness: Harness) {
        for _ in 0..<10 {
            graph.recomposer.commitAll()
            graph.computeLayout(width: harness.width, height: 600)
        }
    }
    private func scene(grid: Bool, _ body: (Harness, ViewGraph, PlatformInputContext, EventDispatcher) throws -> Void)
        rethrows
    {
        try GlobalTestLock.locked {
            let previous = TextEnvironmentHolder.current
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = previous }
            let context = PlatformInputContext()
            let scheduler = AnimatorScheduler()
            try context.withCurrent {
                try AnimatorScheduler.$current.withValue(scheduler) {
                    let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                    let harness = Harness(grid: grid)
                    let input = EventDispatcher(
                        tree: graph.tree, interactions: context.interactions,
                        capture: context.pointerCapture, focusChain: context.focusChain)
                    graph.install(root: harness)
                    settle(graph, harness: harness)
                    defer {
                        graph.install(root: EmptyView())
                        scheduler.reset()
                    }
                    try body(harness, graph, context, input)
                }
            }
        }
    }

    @Test(
        "Container reflow preserves draft, real focus and input identity across density and text scale",
        arguments: [false, true])
    func reflow(grid: Bool) throws {
        try scene(grid: grid) { harness, graph, context, input in
            let first = try #require(fields(graph).first)
            let firstID = first.id
            let diagnostics = UIDiagnostics(tree: graph.tree, state: graph.stateRegistry)
            context.focusChain.focus(first)
            input.dispatch(.textInput("Live "))
            settle(graph, harness: harness)
            let draft = harness.name.stringValue
            #expect(draft.contains("Live "))
            for scale: Float in [1, 2] {
                for width: Float in [390, 720, 1280, 390, 720] {
                    for capabilities: UIEnvironment.Input in [
                        [.touch], [.touch, .pointer, .keyboard], [.pointer, .keyboard],
                    ] {
                        harness.width = width
                        harness.scale = scale
                        harness.input = capabilities
                        settle(graph, harness: harness)
                        let current = try #require(fields(graph).first)
                        let title = try label(graph)
                        #expect(current.id == firstID)
                        #expect(context.focusChain.focused?.id == firstID)
                        #expect(harness.name.stringValue == draft)
                        let reported = try diagnostics.queryNodes(text: "Display name", role: "textField")
                        #expect(reported.items.contains { $0.node.id == String(firstID.rawValue) })
                        let position = try #require(
                            reported.items.first { $0.node.id == String(firstID.rawValue) }?.node.absoluteFrame)
                        #expect(abs(position.x - Double(current.absoluteFrame.minX)) < 0.01)
                        #expect(abs(position.y - Double(current.absoluteFrame.minY)) < 0.01)
                        #expect(current.absoluteFrame.minX >= 0 && current.absoluteFrame.maxX <= CGFloat(width))
                        if width == 390 {
                            #expect(title.absoluteFrame.maxY <= current.absoluteFrame.minY)
                        } else {
                            #expect(title.absoluteFrame.maxX <= current.absoluteFrame.minX)
                            #expect(current.frame.width >= 220)
                        }
                        if capabilities.contains(.touch) {
                            #expect(current.frame.height >= 44)
                            if grid {
                                let header = try #require(
                                    nodes(graph.tree.root).first {
                                        $0.attachments[LayoutDebugAttachmentKey.debugName] as? String
                                            == "property-section-header-identity"
                                    })
                                #expect(
                                    header.frame.height >= 44 && current.absoluteFrame.minY >= header.absoluteFrame.maxY
                                )
                            }
                        }
                        #expect(!graph.recomposer.hasPending)
                    }
                }
            }
        }
    }

    @Test("Changing form column count keeps fields mounted and preserves focus while rows reflow")
    func columns() throws {
        try scene(grid: false) { harness, graph, context, _ in
            let original = fields(graph)
            #expect(original.count == 2)
            context.focusChain.focus(original[1])
            harness.columns = 2
            for width: Float in [720, 390, 1280, 390, 720] {
                harness.width = width
                settle(graph, harness: harness)
                let current = fields(graph)
                #expect(current.count == 2 && current[0] === original[0] && current[1] === original[1])
                #expect(context.focusChain.focused === original[1])
                if width == 390 {
                    #expect(current[1].absoluteFrame.minY >= current[0].absoluteFrame.maxY)
                } else {
                    #expect(current[0].absoluteFrame.minY == current[1].absoluteFrame.minY)
                }
                #expect(current.allSatisfy { $0.absoluteFrame.maxX <= CGFloat(width) })
                #expect(!graph.recomposer.hasPending)
            }
        }
    }

    @Test("Explicit label placement overrides adaptive decisions", arguments: [false, true])
    func explicitPlacement(grid: Bool) throws {
        try scene(grid: grid) { harness, graph, _, _ in
            let first = try #require(fields(graph).first)
            for placement: FieldLabelPlacement in [.stacked, .leading, .stacked] {
                harness.placement = placement
                settle(graph, harness: harness)
                let title = try label(graph)
                #expect(fields(graph).first === first)
                if placement == .stacked {
                    #expect(title.absoluteFrame.maxY <= first.absoluteFrame.minY)
                } else {
                    #expect(title.absoluteFrame.maxX <= first.absoluteFrame.minX)
                }
            }
        }
    }

    @Test("Associated labels resolve duplicate field IDs within their own form")
    func labelScope() throws {
        try scene(grid: false) { harness, graph, context, _ in
            graph.install(
                root: Column {
                    Form([FormField("name", "Name") { TextField("First", text: .constant("first")) }])
                    Form([FormField("name", "Name") { TextField("Second", text: .constant("second")) }])
                }.frame(width: 720))
            settle(graph, harness: harness)
            let inputs = fields(graph)
            let labels = nodes(graph.tree.root).filter {
                $0.attachments[ButtonHost.markerKey] != nil && $0.accessibility?.label == "Name"
            }
            #expect(inputs.count == 2 && labels.count == 2)
            labels[1].accessibilityActions.activate?()
            #expect(context.focusChain.focused?.id == inputs[1].id)
            labels[0].accessibilityActions.activate?()
            #expect(context.focusChain.focused?.id == inputs[0].id)
        }
    }
}
