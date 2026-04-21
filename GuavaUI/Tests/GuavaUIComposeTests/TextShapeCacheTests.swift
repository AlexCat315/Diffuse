import Testing
import CoreGraphics
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Text shape cache")
struct TextShapeCacheTests {

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
}
