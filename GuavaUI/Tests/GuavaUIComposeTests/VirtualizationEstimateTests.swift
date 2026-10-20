import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Estimated row heights and virtualized reordering", .serialized)
@MainActor
struct VirtualizationEstimateTests: GuavaUIComposeSerializedSuite {
    @Test("Unknown heights start from the estimate and converge to measured rows")
    func estimatedRows() throws {
        try InteractiveScene.run(width: 300, height: 400) { scene in
            scene.install(VirtualStack(0..<10_000, id: \.self, estimatedRowHeight: 30) { index in
                Box {}.frame(height: index % 2 == 0 ? 50 : 20).debugName("estimated-\(index)")
            }.frame(width: 300, height: 400))
            for _ in 0..<3 { scene.settle() }
            let mounted = scene.all { ($0.attachments[LayoutDebugAttachmentKey.debugName] as? String)?.hasPrefix("estimated-") == true }
            #expect(!mounted.isEmpty && mounted.count < 60)
            let first = try #require(scene.named("estimated-0")), second = try #require(scene.named("estimated-1"))
            #expect(abs(Float(first.frame.height) - 50) < 0.5)
            #expect(abs(second.absoluteFrame.minY - first.absoluteFrame.maxY) < 1)
        }
    }

    @Test("Metrics replace estimates by ID and forget them when the width changes")
    func metricsCache() throws {
        let metrics = EstimatedRowMetrics<Int>()
        let generation = UUID()
        _ = metrics.synchronize(0..<4, id: \.self, generation: generation, width: 200, scaler: .identity,
                                estimate: 10, spacing: 0, offset: 0, viewport: 100)
        #expect(metrics.rows.total == 40)
        #expect(metrics.record(2, height: 30))
        #expect(!metrics.record(2, height: 30.2))
        _ = metrics.synchronize(0..<4, id: \.self, generation: generation, width: 200, scaler: .identity,
                                estimate: 10, spacing: 0, offset: 0, viewport: 100)
        #expect(metrics.rows.total == 60)
        _ = metrics.synchronize(0..<4, id: \.self, generation: generation, width: 260, scaler: .identity,
                                estimate: 10, spacing: 0, offset: 0, viewport: 100)
        #expect(metrics.rows.total == 40)
        #expect(metrics.height(for: 2) == nil)
    }

    @Test("A long reorderable list mounts only the viewport window")
    func reorderWindow() throws {
        try InteractiveScene.run(width: 300, height: 400) { scene in
            var items = Array(0..<1_000)
            scene.install(ReorderableList(items, id: \.self, rowHeight: 36, rowLabel: { "Item \($0)" },
                                          onMove: { from, to in let moved = items.remove(at: from); items.insert(moved, at: to) }) { item, _ in
                Text("Item \(item)").debugName("reorder-row-\(item)")
            }.frame(width: 300, height: 360))
            let rows = scene.all { ($0.attachments[LayoutDebugAttachmentKey.debugName] as? String)?.hasPrefix("reorder-row-") == true }
            #expect(rows.count > 5 && rows.count < 40)
            #expect(scene.named("reorder-row-999") == nil)
            let handle = try #require(scene.labelled("Reorder Item 0, position 1 of 1000"))
            scene.focus.focus(handle)
            scene.key(Scancode.arrowDown)
            #expect(items.prefix(2) == [1, 0])
        }
    }
}
