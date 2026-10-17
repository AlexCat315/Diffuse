import Foundation
import GuavaUIRuntime
import Testing
@testable import GuavaUICompose

@Suite("Navigation stack", .serialized)
struct NavigationStackTests: GuavaUIComposeSerializedSuite {
    private struct Harness: View {
        @State var path: [String]
        @State var rootCount = 7

        init(initialPath: [String]) {
            _path = State(wrappedValue: initialPath)
        }

        var body: some View {
            NavigationStack(path: $path) {
                Column(alignment: .leading, spacing: 8) {
                    Text("Root").font(.headline).navigationTitle("Root").debugName("nav-root")
                    Text("Root count \(rootCount)").font(.body)
                    Button("Increment root") { rootCount += 1 }
                }
            } destination: { route in
                Column(alignment: .leading, spacing: 8) {
                    Text(route).font(.headline).navigationTitle(route).debugName("nav-page-\(route)")
                    Text("Page \(route)").font(.body)
                    Button("Back") { if !path.isEmpty { path.removeLast() } }
                }
            }
            .frame(width: 400, height: 300)
        }
    }

    private func nodes(_ root: Node?) -> [Node] {
        guard let root else { return [] }
        return [root] + root.children.flatMap { nodes($0) }
    }

    private func settle(_ graph: ViewGraph) {
        for _ in 0..<40 {
            graph.recomposer.commitAll()
            graph.computeLayout(width: 400, height: 300)
            AnimatorScheduler.current.tick(deltaTime: 0.05)
        }
    }

    private func withScene(_ harness: Harness, _ body: (ViewGraph) throws -> Void) rethrows {
        try GlobalTestLock.locked {
            let previousText = TextEnvironmentHolder.current
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = previousText }
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: harness)
            settle(graph)
            defer { graph.install(root: EmptyView()) }
            try body(graph)
        }
    }

    private func labels(_ graph: ViewGraph) -> [String] {
        AccessibilityTree.snapshot(root: graph.tree.root!).flatMap { flatten($0) }.map(\.semantics.label)
    }

    private func flatten(_ element: AccessibilityElement) -> [AccessibilityElement] {
        [element] + element.children.flatMap(flatten)
    }

    @Test("Push and pop retain the root and only expose the top page")
    func pushAndPop() throws {
        let harness = Harness(initialPath: [])
        try withScene(harness) { graph in
            #expect(labels(graph).contains("Root"))
            #expect(!labels(graph).contains("details"))

            harness.$rootCount.wrappedValue = 11
            harness.$path.wrappedValue = ["details"]
            settle(graph)
            #expect(labels(graph).contains("details"))
            #expect(!labels(graph).contains("Root"))

            harness.$path.wrappedValue = []
            settle(graph)
            #expect(labels(graph).contains("Root"))
            #expect(labels(graph).contains("Root count 11"))
            #expect(!labels(graph).contains("details"))
        }
    }

    @Test("A non-empty initial path restores the deep link")
    func deepLink() throws {
        try withScene(Harness(initialPath: ["details"])) { graph in
            #expect(labels(graph).contains("details"))
            #expect(!labels(graph).contains("Root"))
        }
    }

    @Test("Multiple pages keep only the last one interactive")
    func multiplePages() throws {
        let harness = Harness(initialPath: [])
        try withScene(harness) { graph in
            harness.$path.wrappedValue = ["details", "settings"]
            settle(graph)
            #expect(labels(graph).contains("settings"))
            #expect(!labels(graph).contains("details"))
            #expect(!labels(graph).contains("Root"))
            harness.$path.wrappedValue = ["details"]
            settle(graph)
            #expect(labels(graph).contains("details"))
            #expect(!labels(graph).contains("settings"))
        }
    }

    private func withFocusedScene(_ harness: Harness,
                                  _ body: (ViewGraph, PlatformInputContext) throws -> Void) rethrows {
        try GlobalTestLock.locked {
            let context = PlatformInputContext()
            let previous = TextEnvironmentHolder.current
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = previous }
            try context.withCurrent {
                let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                graph.install(root: harness)
                settle(graph)
                defer { graph.install(root: EmptyView()) }
                try body(graph, context)
            }
        }
    }

    @Test("A pushed page focuses its title without a visible keyboard ring")
    func titleFocus() throws {
        let harness = Harness(initialPath: [])
        try withFocusedScene(harness) { graph, context in
            #expect(context.focusChain.focused?.accessibility?.identifier == "navigation.title")
            #expect(context.focusChain.focused?.accessibility?.label == "Root")
            harness.$path.wrappedValue = ["details"]
            settle(graph)
            #expect(context.focusChain.focused?.accessibility?.label == "details")
            #expect(context.focusChain.isFocusVisible == false)
            harness.$path.wrappedValue = []
            settle(graph)
            #expect(context.focusChain.focused?.accessibility?.label == "Root")
        }
    }

    @Test("A second path change during the transition is rejected")
    func transitionGuard() throws {
        let harness = Harness(initialPath: [])
        try withFocusedScene(harness) { graph, _ in
            harness.$path.wrappedValue = ["details"]
            graph.recomposer.commitAll()
            graph.computeLayout(width: 400, height: 300)
            AnimatorScheduler.current.tick(deltaTime: 0.01)
            harness.$path.wrappedValue = ["details", "settings"]
            settle(graph)
            #expect(harness.$path.wrappedValue == ["details"])

            harness.$path.wrappedValue = ["details", "settings"]
            settle(graph)
            #expect(harness.$path.wrappedValue == ["details", "settings"])
        }
    }
}
