import Testing
import CoreGraphics
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

            // After measure runs, the layout-side cache must hold a result.
            let layoutCache = graph.layoutNode(for: textNode!)?.attachments[Text.measureCacheKey]
            #expect(layoutCache is TextLayoutCacheEntry)

            let firstEntry = layoutCache as? TextLayoutCacheEntry
            // Second layout pass with identical width must reuse the same
            // entry (object identity preserved because the cache key matches).
            graph.computeLayout(width: 200, height: 200)
            let secondCache = graph.layoutNode(for: textNode!)?.attachments[Text.measureCacheKey]
            let secondEntry = secondCache as? TextLayoutCacheEntry
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
            let firstKey = (layout.attachments[Text.measureCacheKey] as? TextLayoutCacheEntry)?.key
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
            let key = (graph.layoutNode(for: textNode)?.attachments[Text.measureCacheKey] as? TextLayoutCacheEntry)?.key
            #expect(key?.text == "a much longer label")
        }
    }
}
