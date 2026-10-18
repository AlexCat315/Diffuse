import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Scroll keyboard ownership", .serialized)
@MainActor
struct ScrollKeyboardFocusTests: GuavaUIComposeSerializedSuite {
    private final class Harness: View {
        @State var tall = false
        @State var interactive = false
        var body: some View {
            Column {
                ScrollView(.vertical, accessibilityLabel: "Readings") {
                    Column {
                        Text("Reading content").frame(height: tall ? 400 : 20)
                        if interactive { Button("Open reading") {}.accessibilityLabel("Open reading") }
                    }
                }.frame(width: 200, height: 100)
                Button("After readings") {}.accessibilityLabel("After readings")
            }
        }
    }
    private func nodes(_ node: Node?) -> [Node] {
        guard let node else { return [] }
        return [node] + node.children.flatMap(nodes)
    }
    @Test("Only an overflowing viewport without child controls enters the keyboard chain")
    func focusOwnership() throws {
        try GlobalTestLock.locked {
            let old = TextEnvironmentHolder.current; TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = old }
            let context = PlatformInputContext()
            try context.withCurrent {
                let h = Harness(), graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                graph.install(root: h)
                defer { graph.install(root: EmptyView()) }
                func settle() { for _ in 0..<4 { graph.recomposer.commitAll(); graph.computeLayout(width: 300, height: 600) } }
                @MainActor func find(_ label: String) throws -> Node {
                    try #require(nodes(graph.tree.root).first { $0.accessibility?.label == label })
                }
                settle()
                let scroll = try find("Readings"), after = try find("After readings")
                #expect(!scroll.isFocusable)
                context.focusChain.focusNext(in: graph.tree.root!)
                #expect(context.focusChain.focused === after)
                h.tall = true; settle()
                #expect(scroll.isFocusable)
                context.focusChain.focus(scroll)
                h.interactive = true; settle()
                #expect(!scroll.isFocusable && context.focusChain.focused == nil)
                context.focusChain.focusNext(in: graph.tree.root!)
                #expect(context.focusChain.focused === (try find("Open reading")))
                h.interactive = false; settle()
                #expect(scroll.isFocusable)
                context.focusChain.focus(scroll)
                h.tall = false; settle()
                #expect(!scroll.isFocusable && context.focusChain.focused == nil)
                #expect(try find("Readings") === scroll)
            }
        }
    }
}
