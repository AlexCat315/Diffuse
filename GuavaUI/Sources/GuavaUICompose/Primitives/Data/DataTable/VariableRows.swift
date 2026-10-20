import Foundation
import GuavaUIRuntime

/// Row geometry for the display order. Fixed rows are arithmetic; variable
/// rows use prefix sums, so the viewport, scrolling extent, reveal and paging
/// all agree on one source of truth.
struct DataTableRowMetrics {
    let count: Int
    let fixed: Float
    let index: VariableRowIndex<Int>?

    func top(_ row: Int) -> Float { index.map { Float($0.top(of: row)) } ?? Float(row) * fixed }
    func height(_ row: Int) -> Float { index.map { Float($0.height(at: row)) } ?? fixed }
    var total: Float { index.map { Float($0.total) } ?? Float(count) * fixed }

    func visibleRange(offset: Float, viewport: Float, overscan: Int) -> Range<Int> {
        if let index {
            return index.visibleRange(offset: Double(max(0, min(offset, max(0, total - viewport)))),
                                      viewport: Double(viewport), overscan: overscan)
        }
        return FixedVirtualStack<[Int], Int, EmptyView>.visibleRange(count: count, rowStride: fixed, offset: offset,
                                                                    height: viewport, overscan: overscan)
    }

    /// The row containing a content offset.
    func row(at offset: Float) -> Int {
        guard count > 0 else { return 0 }
        if let index { return index.anchor(at: Double(max(0, offset)))?.index ?? 0 }
        return min(count - 1, max(0, Int(offset / max(1, fixed))))
    }
}

/// Variable heights are rebuilt once per model revision, row height or text
/// scale change, never while scrolling.
final class DataTableRowHeightCache {
    private struct Key: Equatable {
        let revision: UInt64
        let count: Int
        let minimum: Float
        let scale: Float
    }
    private var key: Key?
    private var index: VariableRowIndex<Int>?

    func metrics<Record: Sendable, ID: Hashable & Sendable>(
        model: DataTableModel<Record, ID>, minimum: Float, scaler: TextScaler, rowHeight: ((Record) -> Float)?
    ) -> DataTableRowMetrics {
        guard let rowHeight else { return DataTableRowMetrics(count: model.count, fixed: minimum, index: nil) }
        let next = Key(revision: model.revision, count: model.count, minimum: minimum, scale: scaler.factor)
        if key != next || index == nil {
            var rows = index ?? VariableRowIndex<Int>()
            let heights = (0..<model.count).map { max(minimum, scaler.scale(rowHeight(model.record(at: $0)))) }
            rows.replace(ids: Array(0..<model.count), heights: heights, spacing: 0)
            index = rows; key = next
        }
        return DataTableRowMetrics(count: model.count, fixed: minimum, index: index)
    }
}
