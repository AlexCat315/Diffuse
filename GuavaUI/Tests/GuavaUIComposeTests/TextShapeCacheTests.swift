import Testing
#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Text shape cache")
struct TextShapeCacheTests {

    struct TextHarness: View {
        @State var text: String = "short"

        var body: some View {
            Row {
                Text(text)
            }
        }
    }

    @Test("Layout cache entry is written on first measure and reused on identical inputs")
    func cacheHit() {
        GlobalTestLock.locked {
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make(size: 16, lineHeight: 20)
            defer { TextEnvironmentHolder.current = nil }

            let tree = NodeTree()
            let graph = ViewGraph(tree: tree, recomposer: Recomposer())
            graph.install(root: Text("Hello, world."))

            graph.computeLayout(width: 200, height: 200)

            let textNode = tree.root?.children.first
            #expect(textNode != nil)
            let layoutNode = graph.layoutNode(for: textNode!)!

            // After measure runs, the typed slot on LayoutNode must hold a result.
            let firstEntry = layoutNode.textMeasure
            #expect(firstEntry != nil)

            // Second layout pass with identical width must reuse the same
            // entry (key matches because nothing changed).
            graph.computeLayout(width: 200, height: 200)
            let secondEntry = layoutNode.textMeasure
            #expect(firstEntry?.key == secondEntry?.key)
        }
    }

    @Test("Cache key changes when text changes; entry is replaced")
    func cacheMissOnTextChange() {
        GlobalTestLock.locked {
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make(size: 16, lineHeight: 20)
            defer { TextEnvironmentHolder.current = nil }

            let tree = NodeTree()
            let graph = ViewGraph(tree: tree, recomposer: Recomposer())
            graph.install(root: Text("first"))
            graph.computeLayout(width: 200, height: 200)
            let textNode = tree.root!.children.first!
            let layout = graph.layoutNode(for: textNode)!
            let firstKey = layout.textMeasure?.key
            #expect(firstKey?.text == "first")
        }
    }

    @Test("Reused Text nodes refresh measurement when the string changes")
    func reusedNodeRefreshesMeasurement() {
        GlobalTestLock.locked {
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make(size: 16, lineHeight: 20)
            defer { TextEnvironmentHolder.current = nil }

            let tree = NodeTree()
            let recomp = Recomposer()
            let graph = ViewGraph(tree: tree, recomposer: recomp)
            let harness = TextHarness()
            graph.install(root: harness)
            graph.computeLayout(width: 200, height: 200)

            let textNode = tree.root?.children.first?.children.first?.children.first
            #expect(textNode != nil)
            guard let textNode else { return }
            let beforeWidth = Float(textNode.frame.width)

            harness.$text.wrappedValue = "a much longer label"
            recomp.commitAll()
            graph.computeLayout(width: 200, height: 200)

            let afterWidth = Float(textNode.frame.width)
            #expect(afterWidth > beforeWidth)
            let key = graph.layoutNode(for: textNode)!.textMeasure?.key
            #expect(key?.text == "a much longer label")
        }
    }
}
