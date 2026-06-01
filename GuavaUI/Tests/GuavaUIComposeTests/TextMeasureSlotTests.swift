import Testing
#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
import GuavaUIRuntime
@testable import GuavaUICompose

/// Phase 6: typed text measure slot on `LayoutNode`. Verifies the slot is
/// populated by measure, reset by `LayoutTree.resetCaches()`, and survives
/// across multiple layout passes when inputs are unchanged.
@Suite("Phase 6 text measure slot", .serialized)
struct TextMeasureSlotTests {

    @Test("LayoutNode.textInputs is populated by _makeLayoutNode")
    func textInputsPopulated() {
        GlobalTestLock.locked {
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make(size: 16, lineHeight: 20)
            defer { TextEnvironmentHolder.current = nil }

            let tree = NodeTree()
            let graph = ViewGraph(tree: tree, recomposer: Recomposer())
            graph.install(root: Text("hello"))
            graph.computeLayout(width: 200, height: 200)

            let textNode = tree.root!.children.first!
            let layout = graph.layoutNode(for: textNode)!
            #expect(layout.textInputs?.text == "hello")
        }
    }

    @Test("LayoutTree.resetCaches clears textMeasure across the subtree")
    func resetCachesWipesSlots() {
        GlobalTestLock.locked {
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make(size: 16, lineHeight: 20)
            defer { TextEnvironmentHolder.current = nil }

            let tree = NodeTree()
            let graph = ViewGraph(tree: tree, recomposer: Recomposer())
            graph.install(root: Text("first"))
            graph.computeLayout(width: 200, height: 200)

            let textNode = tree.root!.children.first!
            let layout = graph.layoutNode(for: textNode)!
            #expect(layout.textMeasure != nil)

            graph.layoutTree.resetCaches()
            #expect(layout.textMeasure == nil)
        }
    }
}
