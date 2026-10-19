import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Variable-height virtualization", .serialized)
struct VirtualStackVariableRowsTests: GuavaUIComposeSerializedSuite {
    @Test("prefix updates and offset lookup agree with uneven row extents")
    func prefixIndex() {
        var sums = VirtualRowSums([10, 30, 5, 50])
        #expect(sums.total == 95)
        #expect(sums.prefix(3) == 45)
        #expect(sums.row(at: -1) == 0)
        #expect(sums.row(at: 0) == 0)
        #expect(sums.row(at: 10) == 1)
        #expect(sums.row(at: 44.99) == 2)
        #expect(sums.row(at: 95) == 4)
        sums.update(at: 1, to: 60)
        #expect(sums.total == 125)
        #expect(sums.prefix(3) == 75)
        #expect(sums.row(at: 70) == 2)
        sums.rebuild([])
        #expect(sums.total == 0)
        #expect(sums.row(at: 0) == 0)
    }

    @Test("ranges honor exact boundaries, gaps, overscan, and empty content")
    func visibleRanges() {
        var rows = VariableRowIndex<Int>()
        rows.replace(ids: [0, 1, 2, 3], heights: [10, 30, 5, 50], spacing: 2)
        #expect(rows.total == 101)
        #expect(rows.top(of: 2) == 44)
        #expect(rows.visibleRange(offset: 12, viewport: 32, overscan: 0) == 1..<2)
        #expect(rows.visibleRange(offset: 43, viewport: 7, overscan: 0) == 1..<3)
        #expect(rows.visibleRange(offset: 45, viewport: 5, overscan: 1) == 1..<4)
        #expect(rows.visibleRange(offset: 101, viewport: 30, overscan: 1).isEmpty)
        rows.replace(ids: [], heights: [], spacing: 10)
        #expect(rows.total == 0)
        #expect(rows.visibleRange(offset: 0, viewport: 300, overscan: 3).isEmpty)
    }

    @Test("height changes, insertions, reorder, and deletion retain a stable row anchor")
    func stableAnchors() throws {
        var rows = VariableRowIndex<Int>()
        rows.replace(ids: [0, 1, 2, 3], heights: [20, 30, 40, 200], spacing: 2)
        let anchor = try #require(rows.anchor(at: 59))
        #expect(anchor.id == 2)
        #expect(anchor.inset == 5)
        rows.replace(ids: [0, 1, 2, 3], heights: [70, 30, 40, 200], spacing: 2)
        #expect(rows.offset(for: anchor, viewport: 100) == 109)
        rows.replace(ids: [9, 2, 0, 1, 3], heights: [10, 40, 70, 30, 200], spacing: 2)
        #expect(rows.offset(for: anchor, viewport: 100) == 17)
        rows.replace(ids: [9, 0, 1, 3], heights: [10, 70, 30, 200], spacing: 2)
        #expect(rows.offset(for: anchor, viewport: 100) == 89)
        rows.replace(ids: [9], heights: [5], spacing: 2)
        #expect(rows.offset(for: anchor, viewport: 100) == 0)
    }

    private struct Item {
        let id: Int
        var height: Float
    }

    @Test("scrolling reuses measurements and width, scale, and input changes invalidate them")
    func measurementInvalidation() {
        let cache = VariableRowMetrics<Int>()
        let generation = UUID()
        let data = (0..<10_000).map { Item(id: $0, height: Float(20 + $0 % 7)) }
        var measurements = 0
        func height(_ item: Item, _ width: Float, _ scaler: TextScaler) -> Float {
            measurements += 1
            return scaler.scale(item.height) * (width < 250 ? 2 : 1)
        }
        _ = cache.synchronize(data, id: \.id, generation: generation, width: 300,
                              scaler: .identity, spacing: 2, offset: 0, viewport: 200,
                              rowHeight: height)
        #expect(measurements == 10_000)
        let overscroll = cache.synchronize(data, id: \.id, generation: generation, width: 300,
                                           scaler: .identity, spacing: 2, offset: -12, viewport: 200,
                                           rowHeight: height)
        #expect(overscroll == -12)
        let resized = cache.synchronize(data, id: \.id, generation: generation, width: 300,
                                        scaler: .identity, spacing: 2, offset: -12, viewport: 300,
                                        rowHeight: height)
        #expect(resized == 0)
        for offset in stride(from: 0.0, to: 10_000, by: 20) {
            _ = cache.synchronize(data, id: \.id, generation: generation, width: 300,
                                  scaler: .identity, spacing: 2, offset: offset, viewport: 200,
                                  rowHeight: height)
            #expect(cache.rows.visibleRange(offset: offset, viewport: 200, overscan: 3).count < 20)
        }
        #expect(measurements == 10_000)
        _ = cache.synchronize(data, id: \.id, generation: generation, width: 200,
                              scaler: .identity, spacing: 2, offset: 0, viewport: 200,
                              rowHeight: height)
        #expect(measurements == 20_000)
        #expect(cache.rows.height(at: 0) == 40)
        _ = cache.synchronize(data, id: \.id, generation: generation, width: 200,
                              scaler: .init(2), spacing: 2, offset: 0, viewport: 200,
                              rowHeight: height)
        #expect(measurements == 30_000)
        #expect(cache.rows.height(at: 0) == 80)
        var changed = data
        changed[0].height = 40
        _ = cache.synchronize(changed, id: \.id, generation: UUID(), width: 200,
                              scaler: .init(2), spacing: 2, offset: 0, viewport: 200,
                              rowHeight: height)
        #expect(cache.rows.height(at: 0) == 160)
    }

    @Test("reveal handles tall rows, out-of-bounds indices, and shrink")
    func revealAndClamp() {
        var rows = VariableRowIndex<Int>()
        rows.replace(ids: [0, 1, 2, 3], heights: [20, 300, 40, 50], spacing: 2)
        #expect(rows.reveal(1, offset: 0, viewport: 100) == 22)
        #expect(rows.reveal(2, offset: 0, viewport: 100) == 264)
        #expect(rows.reveal(-1, offset: 100, viewport: 100) == 0)
        #expect(rows.reveal(100, offset: 0, viewport: 100) == 316)
        rows.replace(ids: [0], heights: [.nan], spacing: .infinity)
        #expect(rows.height(at: 0) == 1)
        #expect(rows.clamp(10_000, viewport: 100) == 0)
    }

    private final class Counters {
        var measurements = 0
        var constructions = 0
        var width: Float = 0
    }

    private struct Harness: View {
        @State var data = (0..<10_000).map { Item(id: $0, height: Float(24 + $0 % 5 * 4)) }
        @State var target: Int? = nil
        @State var width: Float = 300
        @State var scale: Float = 1
        let counters: Counters

        var body: some View {
            VirtualStack(data, id: \.id, rowHeight: { item, width, scaler in
                counters.measurements += 1
                counters.width = width
                return scaler.scale(item.height) * (width < 250 ? 2 : 1)
            }, spacing: 2, scrollToIndex: target) { item in
                makeRow(item)
            }.frame(width: width, height: 200).textScaler(.init(scale))
        }

        private func makeRow(_ item: Item) -> some View {
            counters.constructions += 1
            return Box {}.flex(1).debugName("variable-row-\(item.id)")
        }
    }

    private func nodes(_ node: Node?) -> [Node] {
        guard let node else { return [] }
        return [node] + node.children.flatMap { nodes($0) }
    }

    private func settle(_ graph: ViewGraph) {
        for _ in 0..<6 {
            graph.recomposer.commitAll()
            graph.computeLayout(width: 400, height: 300)
        }
    }

    @Test("viewport mounts bounded rows, reveals a distant target, and preserves position at 200% text scale")
    func viewportIntegration() throws { try GlobalTestLock.locked {
        let context = PlatformInputContext()
        try context.withCurrent {
            let counters = Counters()
            let harness = Harness(counters: counters)
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: harness)
            settle(graph)
            func mounted() -> [Node] {
                nodes(graph.tree.root).filter {
                    ($0.attachments[LayoutDebugAttachmentKey.debugName] as? String)?.hasPrefix("variable-row-") == true
                }
            }
            #expect(mounted().count <= 16)
            #expect(counters.measurements == 10_000)
            #expect(counters.width == 288)
            let measurements = counters.measurements
            let input = EventDispatcher(tree: graph.tree, interactions: context.interactions,
                                        capture: context.pointerCapture, focusChain: context.focusChain)
            input.dispatch(.mouseWheel(MouseWheelEvent(x: 0, y: -20, mouseX: 100, mouseY: 100)))
            settle(graph)
            #expect(counters.measurements == measurements)
            #expect(mounted().count <= 16)
            harness.$target.wrappedValue = 9_000
            settle(graph)
            let target = try #require(mounted().first {
                $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == "variable-row-9000"
            })
            #expect(target.absoluteFrame.minY >= 0)
            #expect(target.absoluteFrame.maxY <= 201)
            let scroll = try #require(nodes(graph.tree.root).first { $0.attachments[ScrollReveal.handlerKey] != nil })
            let anchored = try #require(mounted().first { $0.absoluteFrame.maxY > 0 })
            let anchorName = anchored.attachments[LayoutDebugAttachmentKey.debugName] as? String
            let anchorY = anchored.absoluteFrame.minY
            harness.$scale.wrappedValue = 2
            settle(graph)
            let scaled = try #require(mounted().first { $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == anchorName })
            #expect(abs(scaled.absoluteFrame.minY - anchorY) < 0.1)
            #expect(mounted().count <= 16)
            harness.$width.wrappedValue = 200
            settle(graph)
            #expect(counters.width == 188)
            #expect(mounted().contains { $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == anchorName })
            #expect(scroll.contentOffset.y > 100_000)
            harness.$data.wrappedValue = Array(harness.data.prefix(3))
            harness.$target.wrappedValue = nil
            settle(graph)
            #expect(mounted().count == 3)
            #expect(scroll.contentOffset.y <= 200)
        }
    } }
}
