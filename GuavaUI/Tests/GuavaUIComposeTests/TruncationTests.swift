import Foundation
import GuavaUIRuntime
import Testing
@testable import GuavaUICompose

@Suite("Single-line truncation", .serialized)
struct TruncationTests: GuavaUIComposeSerializedSuite {
    private let longTitle = "A very long action label that cannot fit in a narrow rail"

    private struct Harness: View {
        let title: String
        @State var date: Date? = nil

        var body: some View {
            Column(alignment: .leading, spacing: 8) {
                Box(direction: .column, alignItems: .stretch) {
                    Button(title) {}
                }.frame(width: 150)
                Box(direction: .column, alignItems: .stretch) {
                    Link(title) {}
                }.frame(width: 150)
                Box(direction: .column, alignItems: .stretch) {
                    MenuButton(title, entries: [.item(MenuItem(title: "Action") {})])
                }.frame(width: 150)
                DatePicker(selection: $date, configure: {
                    $0.presentation.placeholder = title
                    $0.presentation.width = 220
                })
            }
            .frame(width: 320)
        }
    }

    private func nodes(_ root: Node?) -> [Node] {
        guard let root else { return [] }
        return [root] + root.children.flatMap { nodes($0) }
    }

    private func settle(_ graph: ViewGraph) {
        for _ in 0..<6 {
            graph.recomposer.commitAll()
            graph.computeLayout(width: 360, height: 500)
            AnimatorScheduler.current.tick(deltaTime: 0.05)
        }
    }

    @Test("Text titles ellipsize while their accessible name stays complete")
    func titles() throws {
        try GlobalTestLock.locked {
            let context = PlatformInputContext()
            let store = PortalStore()
            context.addScopedAmbient(PortalStoreAmbient(store))
            let previous = TextEnvironmentHolder.current
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = previous }
            try context.withCurrent {
                let harness = Harness(title: longTitle)
                let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                graph.install(root: harness)
                defer { graph.install(root: EmptyView()) }
                settle(graph)
                let all = nodes(graph.tree.root!)
                let labels = all.filter { $0.accessibility?.label == longTitle }
                #expect(labels.count >= 4)
                for node in labels {
                    #expect(node.accessibility?.label == longTitle)
                }
                let texts = all.filter {
                    $0.accessibility?.role == .staticText && $0.accessibility?.label == longTitle
                }
                #expect(!texts.isEmpty)
                for text in texts {
                    #expect(text.clipsToBounds)
                    #expect(text.frame.width <= 240)
                }
            }
        }
    }
}
