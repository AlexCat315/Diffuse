import Foundation
import GuavaUIRuntime
import Testing
@testable import GuavaUICompose

@Suite("Viewport traits", .serialized)
struct ViewportTraitsTests: GuavaUIComposeSerializedSuite {
    private struct Harness: View {
        @State var viewport = UIEnvironment.Viewport()

        var body: some View {
            var environment = UIEnvironment()
            environment.viewport = viewport
            return WidthClassReader { width in
                HeightClassReader { height in
                    OrientationReader { orientation in
                        Column(alignment: .leading, spacing: 4) {
                            Text("width-\(width)")
                            Text("height-\(height)")
                            Text("orientation-\(orientation)")
                        }
                    }
                }
            }
            .surfaceEnvironment(environment)
            .frame(width: 320, height: 240)
        }
    }

    private func nodes(_ root: Node?) -> [Node] {
        guard let root else { return [] }
        return [root] + root.children.flatMap { nodes($0) }
    }

    private func labels(_ graph: ViewGraph) -> Set<String> {
        Set(nodes(graph.tree.root!).compactMap { $0.accessibility?.label })
    }

    private func settle(_ graph: ViewGraph) {
        for _ in 0..<6 {
            graph.recomposer.commitAll()
            graph.computeLayout(width: 360, height: 300)
            AnimatorScheduler.current.tick(deltaTime: 0.05)
        }
    }

    @Test("Viewport thresholds derive height class and orientation")
    func thresholds() {
        var viewport = UIEnvironment.Viewport()
        viewport.width = 390
        viewport.height = 599
        #expect(viewport.widthClass == .compact)
        #expect(viewport.heightClass == .compact)
        #expect(viewport.orientation == .portrait)

        viewport.height = 600
        #expect(viewport.heightClass == .medium)
        viewport.height = 999
        #expect(viewport.heightClass == .medium)
        viewport.height = 1000
        #expect(viewport.heightClass == .expanded)

        viewport.width = 820
        viewport.height = 390
        #expect(viewport.orientation == .landscape)
        viewport.width = 600
        viewport.height = 600
        #expect(viewport.orientation == .landscape)
        viewport.width = 599
        #expect(viewport.orientation == .portrait)
    }

    @Test("Readers recompose when the viewport changes")
    func readers() throws {
        try GlobalTestLock.locked {
            let previous = TextEnvironmentHolder.current
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = previous }
            let harness = Harness()
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: harness)
            settle(graph)
            #expect(labels(graph).contains("width-expanded"))
            #expect(labels(graph).contains("height-medium"))
            #expect(labels(graph).contains("orientation-landscape"))

            harness.$viewport.wrappedValue.width = 390
            harness.$viewport.wrappedValue.height = 500
            settle(graph)
            #expect(labels(graph).contains("width-compact"))
            #expect(labels(graph).contains("height-compact"))
            #expect(labels(graph).contains("orientation-portrait"))

            harness.$viewport.wrappedValue.width = 1200
            harness.$viewport.wrappedValue.height = 1100
            settle(graph)
            #expect(labels(graph).contains("width-expanded"))
            #expect(labels(graph).contains("height-expanded"))
            #expect(labels(graph).contains("orientation-landscape"))
        }
    }
}
