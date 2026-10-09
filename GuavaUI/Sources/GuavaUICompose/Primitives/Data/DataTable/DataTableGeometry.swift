import Foundation

/// Prefix widths support a horizontal binary search. Frozen columns are
/// outside the moving viewport and never disappear from its visible window.
struct DataTableColumnGeometry {
    let widths: [Float]
    let starts: [Float]
    let frozenCount: Int
    let totalWidth: Float
    init(widths: [Float], frozenCount: Int) {
        self.widths = widths; self.frozenCount = min(max(0, frozenCount), max(0, widths.count - 1))
        var starts: [Float] = []; var width: Float = 0
        for value in widths { starts.append(width); width += value }
        self.starts = starts; totalWidth = width
    }
    var frozenWidth: Float { frozenCount < starts.count ? starts[frozenCount] : 0 }
    var movingWidth: Float { totalWidth - frozenWidth }
    func visibleColumns(offset: Float, width: Float) -> Range<Int> {
        guard frozenCount < widths.count else { return frozenCount..<frozenCount }
        let left = max(0, offset) + frozenWidth, right = left + max(1, width)
        func insertion(_ value: Float) -> Int {
            var lower = frozenCount, upper = starts.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if starts[middle] < value { lower = middle + 1 } else { upper = middle }
            }
            return lower
        }
        let lower = max(frozenCount, insertion(left) - 1)
        return lower..<min(widths.count, max(lower + 1, insertion(right) + 1))
    }
}
