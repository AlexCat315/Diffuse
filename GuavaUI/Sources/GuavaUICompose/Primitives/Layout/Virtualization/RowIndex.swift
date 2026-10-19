import Foundation

/// Prefix sums use Double so large collections do not accumulate Float-sized
/// position errors. Point changes and offset searches are logarithmic.
struct VirtualRowSums {
    private var values: [Double] = []
    private var tree: [Double] = [0]

    var count: Int { values.count }
    var total: Double { prefix(count) }

    init(_ values: [Double] = []) { rebuild(values) }

    mutating func rebuild(_ values: [Double]) {
        self.values = values
        tree = [0] + values
        for index in 1..<tree.count {
            let parent = index + (index & -index)
            if parent < tree.count { tree[parent] += tree[index] }
        }
    }

    mutating func update(at index: Int, to value: Double) {
        let delta = value - values[index]
        guard delta != 0 else { return }
        values[index] = value
        var cursor = index + 1
        while cursor < tree.count {
            tree[cursor] += delta
            cursor += cursor & -cursor
        }
    }

    func prefix(_ end: Int) -> Double {
        var cursor = min(max(0, end), count)
        var sum: Double = 0
        while cursor > 0 {
            sum += tree[cursor]
            cursor -= cursor & -cursor
        }
        return sum
    }

    /// The row whose extent contains offset, or count at/past the end.
    func row(at offset: Double) -> Int {
        guard offset >= 0 else { return 0 }
        var index = 0
        var sum: Double = 0
        var step = 1
        while step <= count / 2 { step *= 2 }
        while step > 0 {
            let next = index + step
            if next <= count, sum + tree[next] <= offset {
                index = next
                sum += tree[next]
            }
            step /= 2
        }
        return index
    }
}

struct VirtualRowAnchor<ID: Hashable> {
    let id: ID
    let index: Int
    let inset: Double
}

struct VariableRowIndex<ID: Hashable> {
    private(set) var ids: [ID] = []
    private var positions: [ID: Int] = [:]
    private var heights: [Double] = []
    private var sums = VirtualRowSums()
    private(set) var spacing: Double = 0

    var count: Int { ids.count }
    var total: Double { max(0, sums.total - (count > 0 ? spacing : 0)) }

    mutating func replace(ids: [ID], heights: [Float], spacing: Float) {
        precondition(ids.count == heights.count)
        let nextSpacing = spacing.isFinite ? Double(max(0, spacing)) : 0
        let nextHeights = heights.map { $0.isFinite ? Double(max(1, $0)) : 1 }
        if self.ids == ids, self.spacing == nextSpacing {
            let changes = nextHeights.indices.filter { self.heights[$0] != nextHeights[$0] }
            // Batch invalidation (e.g. text scaling) is linear; a few changed
            // rows reuse the prefix tree instead of rebuilding all sums.
            let updateLimit = max(1, count / max(1, Int(log2(Double(max(2, count))))))
            if changes.count <= updateLimit {
                for index in changes { sums.update(at: index, to: nextHeights[index] + nextSpacing) }
            } else {
                sums.rebuild(nextHeights.map { $0 + nextSpacing })
            }
        } else {
            positions.removeAll(keepingCapacity: true)
            positions.reserveCapacity(ids.count)
            for (index, id) in ids.enumerated() {
                precondition(positions.updateValue(index, forKey: id) == nil,
                             "VirtualStack requires unique row IDs")
            }
            self.ids = ids
            sums.rebuild(nextHeights.map { $0 + nextSpacing })
        }
        self.heights = nextHeights
        self.spacing = nextSpacing
    }

    func top(of index: Int) -> Double { sums.prefix(index) }
    func height(at index: Int) -> Double { heights[index] }
    func extent(at index: Int) -> Double { heights[index] + (index + 1 < count ? spacing : 0) }

    func visibleRange(offset: Double, viewport: Double, overscan: Int) -> Range<Int> {
        guard count > 0, offset < total else { return count..<count }
        let start = max(0, offset)
        let first = min(count - 1, sums.row(at: start))
        let end = min(total, start + max(1, viewport))
        let last = min(count, sums.row(at: end.nextDown) + 1)
        let extra = max(0, overscan)
        return max(0, first - min(first, extra))..<min(count, last + min(count - last, extra))
    }

    func anchor(at offset: Double) -> VirtualRowAnchor<ID>? {
        guard count > 0 else { return nil }
        let index = min(count - 1, sums.row(at: max(0, offset)))
        return VirtualRowAnchor(id: ids[index], index: index, inset: max(0, offset - top(of: index)))
    }

    func offset(for anchor: VirtualRowAnchor<ID>, viewport: Double) -> Double {
        guard count > 0 else { return 0 }
        let index = positions[anchor.id] ?? min(anchor.index, count - 1)
        return clamp(top(of: index) + min(anchor.inset, extent(at: index)), viewport: viewport)
    }

    func clamp(_ offset: Double, viewport: Double) -> Double {
        max(0, min(offset, max(0, total - max(0, viewport))))
    }

    func reveal(_ index: Int, offset: Double, viewport: Double) -> Double {
        guard count > 0 else { return 0 }
        let row = max(0, min(index, count - 1))
        let top = top(of: row)
        let bottom = top + heights[row]
        var result = offset
        if top < offset || heights[row] > viewport { result = top }
        else if bottom > offset + viewport { result = bottom - viewport }
        return clamp(result, viewport: viewport)
    }
}
