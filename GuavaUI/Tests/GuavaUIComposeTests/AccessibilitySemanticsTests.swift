import Foundation
import GuavaUIRuntime
import Testing
@testable import GuavaUICompose

@Suite("Accessibility semantics", .serialized)
struct AccessibilitySemanticsTests: GuavaUIComposeSerializedSuite {
    private struct ScrollHarness: View {
        var body: some View {
            ScrollView(.vertical, accessibilityLabel: "Timeline") {
                Box(direction: .column, alignItems: .stretch, spacing: 0) {
                    for index in 0..<20 {
                        AnyView(Text("Event \(index)").frame(height: 20))
                    }
                }
            }
            .frame(width: 220, height: 100)
        }
    }

    private struct SelectHarness: View {
        @State var selection = 1
        @State var combo: Int? = 1

        var body: some View {
            Column(alignment: .leading, spacing: 12) {
                Select(selection: $selection, options: [
                    SelectOption(value: 1, label: "One"),
                    SelectOption(value: 2, label: "Two")
                ])
                Combobox(selection: $combo, options: [
                    SelectOption(value: 1, label: "Alpha"),
                    SelectOption(value: 2, label: "Beta")
                ])
            }
            .frame(width: 260)
        }
    }

    private func nodes(_ root: Node?) -> [Node] {
        guard let root else { return [] }
        return [root] + root.children.flatMap { nodes($0) }
    }

    private func settle(_ graph: ViewGraph) {
        for _ in 0..<8 {
            graph.recomposer.commitAll()
            graph.computeLayout(width: 360, height: 400)
            AnimatorScheduler.current.tick(deltaTime: 0.05)
        }
    }

    private func withGraph<Content: View>(_ root: Content,
                                          _ body: (ViewGraph) throws -> Void) rethrows {
        try GlobalTestLock.locked {
            let context = PlatformInputContext()
            let store = PortalStore()
            context.addScopedAmbient(PortalStoreAmbient(store))
            let previous = TextEnvironmentHolder.current
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = previous }
            try context.withCurrent {
                let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                graph.install(root: root)
                defer { graph.install(root: EmptyView()) }
                settle(graph)
                try body(graph)
            }
        }
    }

    private struct DescribedHarness: View {
        var body: some View {
            Column(alignment: .leading, spacing: 8) {
                Text("Uses the system locale")
                    .accessibilityIdentifier("locale-hint")
                Button("Apply") {}
                    .accessibilityDescribedBy("locale-hint")
                Button("Cancel") {}
                    .accessibilityDescribedBy("missing-hint")
            }
        }
    }

    @Test("describedBy appends the referenced element's description")
    func describedBy() throws {
        try withGraph(DescribedHarness()) { graph in
            let snapshot = AccessibilityTree.snapshot(root: graph.tree.root!)
            let buttons = snapshot.filter { $0.semantics.role == .button }
            let apply = try #require(buttons.first { $0.semantics.label == "Apply" })
            #expect(apply.semantics.help.contains("Uses the system locale"))
            let cancel = try #require(buttons.first { $0.semantics.label == "Cancel" })
            #expect(!cancel.semantics.help.contains("Uses the system locale"))
        }
    }

    @Test("Scroll views expose a scroll area with position and page actions")
    func scrollArea() throws {
        try withGraph(ScrollHarness()) { graph in
            let scroll = try #require(nodes(graph.tree.root!).first {
                $0.accessibility?.role == .scrollArea
            })
            #expect(scroll.accessibility?.label == "Timeline")
            #expect(scroll.accessibility?.value == "0%")
            #expect(scroll.accessibility?.help.isEmpty == false)

            scroll.accessibilityActions.increment?()
            settle(graph)
            #expect(scroll.accessibility?.value != "0%")
            #expect(scroll.contentOffset.y > 0)
        }
    }

    @Test("Select and Combobox triggers use the combo box role and full name")
    func comboBoxes() throws {
        try withGraph(SelectHarness()) { graph in
            let comboBoxes = nodes(graph.tree.root!).filter {
                $0.accessibility?.role == .comboBox
            }
            #expect(comboBoxes.count >= 2)
            let labels = Set(comboBoxes.compactMap { $0.accessibility?.label })
            #expect(labels.contains("One"))
            #expect(labels.contains("Alpha"))
            for box in comboBoxes {
                #expect(box.accessibility?.state.isExpanded == false)
                #expect(box.accessibilityActions.activate != nil)
            }
        }
    }
}
