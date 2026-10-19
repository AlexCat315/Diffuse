internal import Foundation
import GuavaUIRuntime

/// Plot coordinates for one chart, shared by drawing, hit-testing and the
/// selection callout so all three agree on where a value is.
struct ChartGeometry {
    struct Mark {
        let series: Int
        let index: Int
        let value: Float
        /// Center x and the y of the value (top of a bar or stacked segment).
        let x: Float
        let y: Float
        /// The y the mark rests on: the zero line, or the segment below when stacked.
        let baseY: Float
        /// Bar column; empty for other marks.
        let bar: UIRect?
        /// The bar end away from the baseline is exposed (not covered by a stacked segment).
        let isOuterEnd: Bool
    }

    let plot: UIRect
    let domain: ClosedRange<Float>
    /// Marks per visible series, in series order. Hidden series have none.
    let marks: [[Mark]]
    let hasBars: Bool
    let sampleCount: Int
    /// Any series with explicit x positions makes hit-testing use true distance.
    let isScatter: Bool

    init(series: [ChartSeries], visible: [Bool], thresholds: [ChartThreshold], style: ChartStyle, plot: UIRect) {
        self.plot = plot
        let shown = series.indices.filter { visible[$0] }
        let hasBars = shown.contains { series[$0].mark == .bar }
        self.hasBars = hasBars
        let sampleCount = shown.map { series[$0].values.count }.max() ?? 0
        self.sampleCount = sampleCount
        isScatter = shown.contains { series[$0].xValues != nil }
        let stacked = style.stacking == .stacked

        // Accumulate stacked bar/area series per index; other marks stand alone.
        var stack = [Float](repeating: 0, count: sampleCount)
        var tops = [[Float]](repeating: [], count: series.count)
        var bases = [[Float]](repeating: [], count: series.count)
        for index in shown {
            let values = series[index].values.map { $0.isFinite ? $0 : 0 }
            let stacks = stacked && (series[index].mark == .bar || series[index].mark == .area)
            bases[index] = values.indices.map { stacks ? stack[$0] : 0 }
            tops[index] = values.indices.map { bases[index][$0] + values[$0] }
            if stacks { for (i, top) in tops[index].enumerated() { stack[i] = top } }
        }
        // Only the last nonzero stacked bar at an index shows a rounded end.
        var outermost = [Int?](repeating: nil, count: sampleCount)
        if stacked {
            for index in shown where series[index].mark == .bar {
                for (i, value) in series[index].values.enumerated() where value.isFinite && value != 0 { outermost[i] = index }
            }
        }

        var extent = shown.flatMap { tops[$0] } + thresholds.map(\.value).filter(\.isFinite)
        if shown.contains(where: { [.bar, .area].contains(series[$0].mark) }) { extent.append(0) }
        var lower = style.minValue ?? extent.min() ?? 0
        var upper = style.maxValue ?? extent.max() ?? 1
        if !lower.isFinite { lower = 0 }
        if !upper.isFinite { upper = 1 }
        if lower > upper { swap(&lower, &upper) }
        if lower == upper { let pad = max(abs(lower) * 0.1, 1); lower -= pad; upper += pad }
        // Scatter points keep clear of the plot edges.
        if isScatter {
            let pad = (upper - lower) * 0.08
            if style.minValue == nil { lower -= pad }
            if style.maxValue == nil { upper += pad }
        }
        let domain = lower...upper
        self.domain = domain

        let xValues = shown.compactMap { series[$0].xValues }.flatMap { $0 }.filter(\.isFinite)
        let xSpan = max((xValues.max() ?? 1) - (xValues.min() ?? 0), 0.001)
        let xDomain = ((xValues.min() ?? 0) - xSpan * 0.04)...((xValues.max() ?? 1) + xSpan * 0.04)
        let barSeries = shown.filter { series[$0].mark == .bar }
        let groups = stacked ? 1 : max(1, barSeries.count)
        let slot = plot.width / Float(max(1, sampleCount))
        // Wide categories breathe (a quarter of the slot, at most 24pt); dense
        // ones keep the authored spacing. Bars inside a group sit 2pt apart.
        let categoryGap = max(style.barSpacing, min(slot * 0.25, 24))
        let innerGap: Float = groups > 1 ? 2 : 0
        let barWidth = max(1, (slot - categoryGap - Float(groups - 1) * innerGap) / Float(groups))

        var marks = [[Mark]](repeating: [], count: series.count)
        for index in shown {
            let item = series[index]
            let group = stacked ? 0 : (barSeries.firstIndex(of: index) ?? 0)
            marks[index] = item.values.indices.map { i in
                let x: Float
                if let xs = item.xValues, xs.indices.contains(i), xs[i].isFinite {
                    x = plot.minX + (xs[i] - xDomain.lowerBound) / (xDomain.upperBound - xDomain.lowerBound) * plot.width
                } else {
                    x = Self.x(index: i, count: sampleCount, hasBars: hasBars, plot: plot)
                }
                let y = Self.y(tops[index][i], domain: domain, plot: plot)
                let baseY = Self.y(bases[index][i], domain: domain, plot: plot)
                var bar: UIRect?
                if item.mark == .bar {
                    let left = plot.minX + Float(i) * slot + categoryGap / 2 + Float(group) * (barWidth + innerGap)
                    bar = UIRect(x: left, y: min(y, baseY), width: barWidth, height: max(1, abs(baseY - y)))
                }
                return Mark(series: index, index: i, value: item.values[i], x: bar.map { $0.minX + $0.width / 2 } ?? x,
                            y: y, baseY: baseY, bar: bar,
                            isOuterEnd: !stacked || outermost[i] == nil || outermost[i] == index)
            }
        }
        self.marks = marks
    }

    static func x(index: Int, count: Int, hasBars: Bool, plot: UIRect) -> Float {
        if hasBars { return plot.minX + (Float(index) + 0.5) * plot.width / Float(max(1, count)) }
        guard count > 1 else { return plot.minX + plot.width / 2 }
        return plot.minX + Float(index) / Float(count - 1) * plot.width
    }

    static func y(_ value: Float, domain: ClosedRange<Float>, plot: UIRect) -> Float {
        let span = max(domain.upperBound - domain.lowerBound, 0.001)
        let ratio = max(0, min((value - domain.lowerBound) / span, 1))
        return plot.maxY - ratio * plot.height
    }

    func y(_ value: Float) -> Float { Self.y(value, domain: domain, plot: plot) }

    /// The mark nearest a plot-space point: the closest x column, then the
    /// series whose value is closest vertically (scatter uses true distance).
    func nearest(x: Float, y: Float) -> Mark? {
        let all = marks.flatMap { $0 }
        guard !all.isEmpty else { return nil }
        if isScatter {
            return all.min { hypotf($0.x - x, $0.y - y) < hypotf($1.x - x, $1.y - y) }
        }
        let column = all.min { abs($0.x - x) < abs($1.x - x) }!.x
        let candidates = all.filter { abs($0.x - column) < 0.5 }
        return candidates.min { abs($0.y - y) < abs($1.y - y) }
    }

    func mark(_ point: ChartPoint) -> Mark? {
        guard marks.indices.contains(point.series), marks[point.series].indices.contains(point.index) else { return nil }
        return marks[point.series][point.index]
    }
}

/// Angles for a pie or donut, starting at 12 o'clock and running clockwise.
struct PieGeometry {
    struct Wedge {
        let index: Int
        let value: Float
        let start: Float
        let end: Float
    }
    let center: (x: Float, y: Float)
    let radius: Float
    let innerRadius: Float
    let wedges: [Wedge]
    let total: Float

    init(slices: [ChartSlice], visible: [Bool], innerRatio: Float, plot: UIRect) {
        center = (plot.minX + plot.width / 2, plot.minY + plot.height / 2)
        radius = max(0, min(plot.width, plot.height) / 2 - 4)
        innerRadius = radius * innerRatio
        let values = slices.indices.map { visible[$0] && slices[$0].value.isFinite ? max(0, slices[$0].value) : 0 }
        total = values.reduce(0, +)
        var angle = -Float.pi / 2
        var wedges: [Wedge] = []
        for (index, value) in values.enumerated() where value > 0 && total > 0 {
            let sweep = value / total * 2 * .pi
            wedges.append(Wedge(index: index, value: value, start: angle, end: angle + sweep))
            angle += sweep
        }
        self.wedges = wedges
    }

    func wedge(atX x: Float, y: Float) -> Wedge? {
        let dx = x - center.x, dy = y - center.y
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance <= radius + 6, distance >= innerRadius - 2 else { return nil }
        var angle = atan2f(dy, dx)
        if angle < -Float.pi / 2 { angle += 2 * .pi }
        return wedges.first { angle >= $0.start && angle < $0.end }
    }

    /// Point on the middle of a wedge's ring, for the callout anchor.
    func anchor(of wedge: Wedge) -> (x: Float, y: Float) {
        let middle = (wedge.start + wedge.end) / 2, r = (radius + innerRadius) / 2
        return (center.x + cosf(middle) * r, center.y + sinf(middle) * r)
    }
}
