import Foundation

/// Authored row heights for `LazyGrid`. Construct variable heights when the
/// data changes and reuse the value while scrolling; prefix sums are built
/// once, and viewport lookup is logarithmic in the number of rows.
/// Supply unscaled logical heights; LazyGrid applies the active TextScaler.
public struct GridRowHeights: Sendable {
    private enum Storage: Sendable {
        case fixed(CGFloat)
        case variable([CGFloat])
    }
    private let storage: Storage
    private var scale: CGFloat = 1

    /// Every row has this height. Fixed rows need no per-row allocation.
    public static func fixed(_ height: CGFloat) -> GridRowHeights {
        GridRowHeights(storage: .fixed(normalizedHeight(height)))
    }

    /// One known height per row, including the last partial row. Heights must
    /// be updated together with the data or column count. Unknown content
    /// heights require an eager `Grid` measurement instead.
    public static func variable(_ heights: [CGFloat]) -> GridRowHeights {
        var offsets: [CGFloat] = [0]
        offsets.reserveCapacity(heights.count + 1)
        for height in heights { offsets.append(offsets[offsets.count - 1] + normalizedHeight(height)) }
        return GridRowHeights(storage: .variable(offsets))
    }

    func validate(rowCount: Int) {
        if case let .variable(offsets) = storage {
            precondition(offsets.count == rowCount + 1,
                         "LazyGrid requires one variable height per row, including the last partial row")
        }
    }

    /// Reuse authored prefix sums when the text scale changes or rows scroll.
    func scaled(by factor: CGFloat) -> Self {
        var result = self
        result.scale *= factor
        return result
    }

    func height(at row: Int) -> CGFloat {
        switch storage {
        case let .fixed(height): return height * scale
        case let .variable(offsets): return (offsets[row + 1] - offsets[row]) * scale
        }
    }

    func offset(of row: Int, spacing: CGFloat) -> CGFloat {
        let gap = GridTrackResolver.finiteNonnegative(spacing)
        switch storage {
        case let .fixed(height): return CGFloat(row) * (height * scale + gap)
        case let .variable(offsets): return offsets[row] * scale + CGFloat(row) * gap
        }
    }

    func totalHeight(rowCount: Int, spacing: CGFloat) -> CGFloat {
        guard rowCount > 0 else { return 0 }
        return offset(of: rowCount - 1, spacing: spacing) + height(at: rowCount - 1)
    }

    func visibleRows(count: Int, offset: CGFloat, viewportHeight: CGFloat,
                     spacing: CGFloat, overscan: Int) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        let gap = GridTrackResolver.finiteNonnegative(spacing)
        let viewport = max(1, GridTrackResolver.finiteNonnegative(viewportHeight))
        let total = totalHeight(rowCount: count, spacing: gap)
        let start = min(GridTrackResolver.finiteNonnegative(offset), max(0, total - viewport))
        let end = start + viewport
        let lower: Int
        let upper: Int
        switch storage {
        case let .fixed(height):
            let stride = height * scale + gap
            lower = boundedIndex(floor((start + gap) / stride), count: count)
            upper = boundedIndex(ceil(end / stride), count: count)
        case .variable:
            lower = firstIndex(count: count) { row in self.offset(of: row, spacing: gap) + height(at: row) > start }
            upper = firstIndex(count: count) { row in self.offset(of: row, spacing: gap) >= end }
        }
        let extra = max(0, overscan)
        return max(0, lower - min(lower, extra))..<min(count, max(lower, upper) + min(count - max(lower, upper), extra))
    }

    private func firstIndex(count: Int, matching predicate: (Int) -> Bool) -> Int {
        var lower = 0
        var upper = count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if predicate(middle) { upper = middle }
            else { lower = middle + 1 }
        }
        return lower
    }

    private func boundedIndex(_ value: CGFloat, count: Int) -> Int {
        guard value > 0 else { return 0 }
        // Clamp before conversion: CGFloat(Int.max) rounds beyond Int.max on
        // 64-bit platforms, including for a compact Range<Int> collection.
        guard value < CGFloat(count) else { return count }
        return Int(value)
    }

    private static func normalizedHeight(_ height: CGFloat) -> CGFloat {
        max(1, GridTrackResolver.finiteNonnegative(height))
    }
}
