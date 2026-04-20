import Testing
import CoreGraphics
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Phase 6.3b Text & Divider")
struct TextDividerTests {

    // Text without a TextEnvironment installed must still build a tree and lay out
    // (measure func returns zero size). This guards primitive contracts when the
    // host hasn't initialised text rendering yet.

    @Test("Text without environment lays out as zero-size leaf")
    func textWithoutEnvironment() {
        TextEnvironmentHolder.current = nil

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root:
            Column {
                Text("Hello")
                Text("World")
            }
        )

        graph.computeLayout(width: 200, height: 200)
        let kids = tree.root?.children.first?.children ?? []
        #expect(kids.count == 2)
        // Both Text nodes report zero intrinsic size without an env.
        #expect(kids[0].frame.size == CGSize(width: 0, height: 0))
    }

    @Test("Text installs a draw callback")
    func textInstallsDrawCallback() {
        TextEnvironmentHolder.current = nil

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: Text("Hi"))

        let textNode = tree.root?.children.first
        #expect(textNode?.draw != nil)
        #expect(textNode?.isHitTestable == false)
    }

    @Test("Divider stretches across cross axis with fixed thickness")
    func dividerStretches() {
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root:
            Column {
                Divider()
            }
        )

        graph.computeLayout(width: 200, height: 200)
        let div = tree.root?.children.first?.children.first
        #expect(div?.frame.size == CGSize(width: 200, height: 1))
        #expect(div?.backgroundColor != nil)
    }

    @Test("Vertical divider gives a 1×N strip")
    func verticalDivider() {
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root:
            Row {
                Divider(thickness: 2, axis: .vertical)
            }
            .frame(width: 200, height: 100)
        )
        graph.computeLayout(width: 200, height: 100)
        let div = tree.root?.children.first?.children.first
        #expect(div?.frame.size == CGSize(width: 2, height: 100))
    }
}
