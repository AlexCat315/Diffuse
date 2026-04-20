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
        GlobalTestLock.locked {
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
    }

    @Test("Text installs a draw callback")
    func textInstallsDrawCallback() {
        GlobalTestLock.locked {
            TextEnvironmentHolder.current = nil

            let tree = NodeTree()
            let graph = ViewGraph(tree: tree, recomposer: Recomposer())
            graph.install(root: Text("Hi"))

            let textNode = tree.root?.children.first
            #expect(textNode?.draw != nil)
            #expect(textNode?.isHitTestable == false)
        }
    }

    @Test("Divider stretches across cross axis with fixed thickness")
    func dividerStretches() {
        GlobalTestLock.locked {
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
    }

    @Test("Vertical divider gives a 1×N strip")
    func verticalDivider() {
        GlobalTestLock.locked {
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

    @Test("LineHeight modifier affects measured text height")
    func lineHeightAffectsMeasurement() {
        GlobalTestLock.locked {
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make(size: 16, lineHeight: 20)
            defer { TextEnvironmentHolder.current = nil }

            let tree = NodeTree()
            let graph = ViewGraph(tree: tree, recomposer: Recomposer())
            graph.install(root: Text("Hello").lineHeight(32))

            graph.computeLayout(width: 200, height: 200)
            let textNode = tree.root?.children.first
            #expect(textNode?.frame.size.height == 32)
        }
    }

    @Test("Font modifier changes measured text size")
    func fontChangesMeasurement() {
        GlobalTestLock.locked {
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make(size: 16, lineHeight: 20)
            defer { TextEnvironmentHolder.current = nil }

            let tree = NodeTree()
            let graph = ViewGraph(tree: tree, recomposer: Recomposer())
            graph.install(root:
                Column {
                    Text("Hello")
                    Text("Hello").font(.system(size: 32, weight: .bold))
                }
            )

            graph.computeLayout(width: 400, height: 200)
            let kids = tree.root?.children.first?.children ?? []
            #expect(kids.count == 2)
            #expect(kids[1].frame.size.width > kids[0].frame.size.width)
            #expect(kids[1].frame.size.height > kids[0].frame.size.height)
        }
    }
}
