internal import Foundation
import GuavaUIRuntime

/// Draws one resolved chart into a draw list. Pure: everything it needs is
/// passed in, so repaint identity stays explicit.
struct ChartPaint {
    let theme: Theme
    let style: ChartStyle
    let selection: ChartPoint?

    func background(_ bounds: UIRect, list: DrawList) {
        if let background = style.background { list.addRect(bounds, color: background.resolve(theme)) }
    }

    func grid(_ geometry: ChartGeometry, list: DrawList) {
        guard style.gridLineCount > 0 else { return }
        let color = style.gridColor.resolve(theme).multipliedAlpha(0.55)
        for line in 0...style.gridLineCount {
            let y = geometry.plot.minY + geometry.plot.height * Float(line) / Float(style.gridLineCount)
            list.addLine(fromX: geometry.plot.minX, fromY: y, toX: geometry.plot.maxX, toY: y, thickness: 1, color: color)
        }
    }

    func thresholds(_ thresholds: [ChartThreshold], geometry: ChartGeometry, list: DrawList) {
        for threshold in thresholds where threshold.value.isFinite {
            let y = geometry.y(threshold.value)
            list.addLine(fromX: geometry.plot.minX, fromY: y, toX: geometry.plot.maxX, toY: y,
                         thickness: 1, color: threshold.color.resolve(theme).multipliedAlpha(0.8))
        }
    }

    func series(_ series: [ChartSeries], geometry: ChartGeometry, list: DrawList) {
        // Fills first, so lines and points of every series stay on top.
        for (index, item) in series.enumerated() where item.mark == .area {
            area(geometry.marks[index], color: item.color.resolve(theme), list: list)
        }
        for (index, item) in series.enumerated() where item.mark == .bar {
            bars(geometry.marks[index], color: item.color.resolve(theme), list: list)
        }
        for (index, item) in series.enumerated() where item.mark == .line || item.mark == .area {
            line(geometry.marks[index], color: item.color.resolve(theme), list: list)
        }
        for (index, item) in series.enumerated() where item.mark == .point {
            for mark in geometry.marks[index] {
                dot(x: mark.x, y: mark.y, radius: 3.5, color: item.color.resolve(theme).multipliedAlpha(0.85), list: list)
            }
        }
    }

    func markers(_ markers: [ChartMarker], geometry: ChartGeometry, list: DrawList) {
        guard geometry.sampleCount > 0 else { return }
        for marker in markers {
            let index = max(0, min(marker.index, geometry.sampleCount - 1))
            let x = ChartGeometry.x(index: index, count: geometry.sampleCount, hasBars: geometry.hasBars, plot: geometry.plot)
            list.addLine(fromX: x, fromY: geometry.plot.minY, toX: x, toY: geometry.plot.maxY,
                         thickness: marker.width, color: marker.color.resolve(theme))
        }
    }

    /// A vertical rule through the selected column and a ringed dot on the value.
    func selection(_ series: [ChartSeries], geometry: ChartGeometry, list: DrawList) {
        guard let selection, let mark = geometry.mark(selection) else { return }
        let rule = theme.colors.onSurfaceMuted.multipliedAlpha(0.35)
        list.addLine(fromX: mark.x, fromY: geometry.plot.minY, toX: mark.x, toY: geometry.plot.maxY, thickness: 1, color: rule)
        guard mark.bar == nil else { return }
        dot(x: mark.x, y: mark.y, radius: 6, color: theme.colors.surface, list: list)
        dot(x: mark.x, y: mark.y, radius: 4, color: series[mark.series].color.resolve(theme), list: list)
    }

    func pie(_ slices: [ChartSlice], geometry: PieGeometry, list: DrawList) {
        guard geometry.radius > 2 else { return }
        // A surface-colored gap separates slices without an outline.
        let gap: Float = geometry.wedges.count > 1 ? 1.5 : 0
        for wedge in geometry.wedges {
            let selected = selection?.index == wedge.index
            let dimmed = selection != nil && !selected
            var color = slices[wedge.index].resolvedColor(at: wedge.index).resolve(theme)
            if dimmed { color = color.multipliedAlpha(0.55) }
            ring(geometry, wedge: wedge, outer: geometry.radius + (selected ? 4 : 0), gap: gap, color: color, list: list)
        }
    }

    // MARK: Primitives

    private func line(_ marks: [ChartGeometry.Mark], color: Color, list: DrawList) {
        guard marks.count > 1 else {
            if let mark = marks.first { dot(x: mark.x, y: mark.y, radius: style.lineWidth, color: color, list: list) }
            return
        }
        for (a, b) in zip(marks, marks.dropFirst()) {
            list.addLine(fromX: a.x, fromY: a.y, toX: b.x, toY: b.y, thickness: style.lineWidth, color: color)
        }
        // Round joins hide the notches butt-capped segments leave at bends.
        if style.lineWidth > 1 {
            for mark in marks.dropFirst().dropLast() { dot(x: mark.x, y: mark.y, radius: style.lineWidth / 2, color: color, list: list) }
        }
    }

    private func area(_ marks: [ChartGeometry.Mark], color: Color, list: DrawList) {
        let fill = color.multipliedAlpha(0.2)
        for (a, b) in zip(marks, marks.dropFirst()) {
            list.addTriangle(a.x, a.y, b.x, b.y, b.x, b.baseY, color: fill)
            list.addTriangle(a.x, a.y, b.x, b.baseY, a.x, a.baseY, color: fill)
        }
    }

    private func bars(_ marks: [ChartGeometry.Mark], color: Color, list: DrawList) {
        for mark in marks {
            guard let rect = mark.bar else { continue }
            let dimmed = selection != nil && selection != ChartPoint(series: mark.series, index: mark.index)
            let fill = dimmed ? color.multipliedAlpha(0.45) : color
            // Round the end away from the baseline only, and only where no
            // stacked segment sits on top of it.
            guard mark.isOuterEnd else { list.addRect(rect, color: fill); continue }
            let radius = min(3, rect.width / 2, rect.height / 2)
            list.addRoundedRect(rect, radius: radius, color: fill)
            let towardBase = mark.y <= mark.baseY
            let square = UIRect(x: rect.minX, y: towardBase ? rect.maxY - radius : rect.minY, width: rect.width, height: radius)
            if radius > 0 { list.addRect(square, color: fill) }
        }
    }

    private func dot(x: Float, y: Float, radius: Float, color: Color, list: DrawList) {
        list.addRoundedRect(UIRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2), radius: radius, color: color)
    }

    private func ring(_ geometry: PieGeometry, wedge: PieGeometry.Wedge, outer: Float, gap: Float, color: Color, list: DrawList) {
        let inner = geometry.innerRadius
        let steps = max(2, Int((wedge.end - wedge.start) / (2 * .pi) * 96))
        // Trim the gap as an arc length at each radius so it stays parallel.
        func point(_ angle: Float, _ radius: Float) -> (Float, Float) {
            (geometry.center.x + cosf(angle) * radius, geometry.center.y + sinf(angle) * radius)
        }
        for step in 0..<steps {
            let t0 = Float(step) / Float(steps), t1 = Float(step + 1) / Float(steps)
            let a0 = wedge.start + (wedge.end - wedge.start) * t0, a1 = wedge.start + (wedge.end - wedge.start) * t1
            let outerTrim = gap / 2 / max(outer, 1), innerTrim = inner > 0 ? gap / 2 / inner : 0
            let o0 = point(max(a0, wedge.start + outerTrim), outer), o1 = point(min(a1, wedge.end - outerTrim), outer)
            if inner <= 0.5 {
                list.addTriangle(geometry.center.x, geometry.center.y, o0.0, o0.1, o1.0, o1.1, color: color)
            } else {
                let i0 = point(max(a0, wedge.start + innerTrim), inner), i1 = point(min(a1, wedge.end - innerTrim), inner)
                list.addTriangle(o0.0, o0.1, o1.0, o1.1, i1.0, i1.1, color: color)
                list.addTriangle(o0.0, o0.1, i1.0, i1.1, i0.0, i0.1, color: color)
            }
        }
    }
}
