#if canImport(CoreGraphics)
import CoreGraphics
#endif
import GuavaUIRuntime

public enum ChartRenderMode: Sendable, Equatable {
    case line
    case bar
}

public struct ChartSeries: Sendable {
    public var values: [Float]
    public var color: SemanticColorRef
    public var mode: ChartRenderMode

    public init(values: [Float],
                color: SemanticColorRef = .accent,
                mode: ChartRenderMode = .line) {
        self.values = values
        self.color = color
        self.mode = mode
    }

    public static func line(_ values: [Float],
                            color: SemanticColorRef = .accent) -> ChartSeries {
        ChartSeries(values: values, color: color, mode: .line)
    }

    public static func bar(_ values: [Float],
                           color: SemanticColorRef = .accent) -> ChartSeries {
        ChartSeries(values: values, color: color, mode: .bar)
    }
}

public struct ChartThreshold: Sendable {
    public var value: Float
    public var color: SemanticColorRef

    public init(value: Float,
                color: SemanticColorRef = .warning) {
        self.value = value
        self.color = color
    }
}

public struct ChartMarker: Sendable {
    public var index: Int
    public var color: SemanticColorRef
    public var width: Float

    public init(index: Int,
                color: SemanticColorRef = .accent,
                width: Float = 1) {
        self.index = index
        self.color = color
        self.width = max(width, 1)
    }
}

public struct ChartStyle: Sendable {
    public var minValue: Float?
    public var maxValue: Float?
    public var gridLineCount: Int
    public var lineWidth: Float
    public var barSpacing: Float
    public var contentInset: Float
    public var background: SemanticColorRef?
    public var gridColor: SemanticColorRef

    public init(minValue: Float? = nil,
                maxValue: Float? = nil,
                gridLineCount: Int = 4,
                lineWidth: Float = 1.5,
                barSpacing: Float = 1,
                contentInset: Float = 4,
                background: SemanticColorRef? = nil,
                gridColor: SemanticColorRef = .divider) {
        self.minValue = minValue
        self.maxValue = maxValue
        self.gridLineCount = max(0, gridLineCount)
        self.lineWidth = max(lineWidth, 0.5)
        self.barSpacing = max(barSpacing, 0)
        self.contentInset = max(contentInset, 0)
        self.background = background
        self.gridColor = gridColor
    }
}

public struct MonitorChart: _PrimitiveView {
    public let series: [ChartSeries]
    public let thresholds: [ChartThreshold]
    public let markers: [ChartMarker]
    public let style: ChartStyle

    public init(series: [ChartSeries],
                thresholds: [ChartThreshold] = [],
                markers: [ChartMarker] = [],
                style: ChartStyle = ChartStyle()) {
        self.series = series
        self.thresholds = thresholds
        self.markers = markers
        self.style = style
    }

    public init(values: [Float],
                color: SemanticColorRef = .accent,
                mode: ChartRenderMode = .line,
                threshold: ChartThreshold? = nil,
                marker: ChartMarker? = nil,
                style: ChartStyle = ChartStyle()) {
        self.init(series: [ChartSeries(values: values, color: color, mode: mode)],
                  thresholds: threshold.map { [$0] } ?? [],
                  markers: marker.map { [$0] } ?? [],
                  style: style)
    }

    public func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = false
        return node
    }

    public func _updateNode(_ node: Node) {
        let snapshot = self
        node.draw = { list, origin in
            snapshot.render(node: node, origin: origin, list: list)
        }
    }

    public func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode()
        layout.height = 64
        return layout
    }

    public func _updateLayout(_ layout: LayoutNode) {
        if (layout.height ?? 0) <= 0 {
            layout.height = 64
        }
    }

    private func render(node: Node, origin: CGPoint, list: DrawList) {
        let frame = node.frame
        let width = Float(frame.width)
        let height = Float(frame.height)
        guard width > 0, height > 0 else { return }

        let originX = Float(origin.x)
        let originY = Float(origin.y)
        let bounds = UIRect(x: originX, y: originY, width: width, height: height)
        let theme = node.theme

        if let background = style.background {
            list.addRect(bounds, color: background.resolve(theme))
        }

        let inset = min(style.contentInset, min(width, height) * 0.35)
        let plot = UIRect(x: originX + inset,
                          y: originY + inset,
                          width: max(0, width - inset * 2),
                          height: max(0, height - inset * 2))
        guard plot.width > 0, plot.height > 0 else { return }

        let domain = chartValueDomain(series: series,
                                      thresholds: thresholds,
                                      style: style)
        drawGrid(plot: plot,
                 domain: domain,
                 theme: theme,
                 list: list)
        drawThresholds(plot: plot,
                       domain: domain,
                       theme: theme,
                       list: list)
        for item in series {
            switch item.mode {
            case .line:
                drawLineSeries(item,
                               plot: plot,
                               domain: domain,
                               theme: theme,
                               list: list)
            case .bar:
                drawBarSeries(item,
                              plot: plot,
                              domain: domain,
                              theme: theme,
                              list: list)
            }
        }
        drawMarkers(plot: plot,
                    sampleCount: series.map(\.values.count).max() ?? 0,
                    theme: theme,
                    list: list)
    }

    private func drawGrid(plot: UIRect,
                          domain: ChartValueDomain,
                          theme: Theme,
                          list: DrawList) {
        guard style.gridLineCount > 0 else { return }
        let color = style.gridColor.resolve(theme).multipliedAlpha(0.55)
        for index in 0...style.gridLineCount {
            let ratio = Float(index) / Float(max(style.gridLineCount, 1))
            let y = plot.minY + plot.height * ratio
            list.addLine(fromX: plot.minX,
                         fromY: y,
                         toX: plot.maxX,
                         toY: y,
                         thickness: 1,
                         color: color)
        }
        _ = domain
    }

    private func drawThresholds(plot: UIRect,
                                domain: ChartValueDomain,
                                theme: Theme,
                                list: DrawList) {
        for threshold in thresholds where threshold.value.isFinite {
            let y = chartY(value: threshold.value, plot: plot, domain: domain)
            list.addLine(fromX: plot.minX,
                         fromY: y,
                         toX: plot.maxX,
                         toY: y,
                         thickness: 1,
                         color: threshold.color.resolve(theme).multipliedAlpha(0.80))
        }
    }

    private func drawLineSeries(_ item: ChartSeries,
                                plot: UIRect,
                                domain: ChartValueDomain,
                                theme: Theme,
                                list: DrawList) {
        let values = finiteValues(item.values)
        guard values.count > 1 else { return }

        let color = item.color.resolve(theme)
        var previous = chartPoint(index: 0,
                                  count: values.count,
                                  value: values[0],
                                  plot: plot,
                                  domain: domain)
        for index in values.indices.dropFirst() {
            let next = chartPoint(index: index,
                                  count: values.count,
                                  value: values[index],
                                  plot: plot,
                                  domain: domain)
            list.addLine(fromX: previous.x,
                         fromY: previous.y,
                         toX: next.x,
                         toY: next.y,
                         thickness: style.lineWidth,
                         color: color)
            previous = next
        }
    }

    private func drawBarSeries(_ item: ChartSeries,
                               plot: UIRect,
                               domain: ChartValueDomain,
                               theme: Theme,
                               list: DrawList) {
        let values = finiteValues(item.values)
        guard !values.isEmpty else { return }

        let count = values.count
        let totalSpacing = style.barSpacing * Float(max(0, count - 1))
        let barWidth = max(1, (plot.width - totalSpacing) / Float(count))
        let zeroY = chartY(value: max(0, domain.min), plot: plot, domain: domain)
        let color = item.color.resolve(theme)

        for (index, value) in values.enumerated() {
            let x = plot.minX + Float(index) * (barWidth + style.barSpacing)
            let y = chartY(value: value, plot: plot, domain: domain)
            let top = min(y, zeroY)
            let bottom = max(y, zeroY)
            let rect = UIRect(x: x,
                              y: top,
                              width: barWidth,
                              height: max(1, bottom - top))
            list.addRect(rect, color: color)
        }
    }

    private func drawMarkers(plot: UIRect,
                             sampleCount: Int,
                             theme: Theme,
                             list: DrawList) {
        guard sampleCount > 0 else { return }
        for marker in markers {
            let clampedIndex = max(0, min(marker.index, sampleCount - 1))
            let x: Float
            if sampleCount == 1 {
                x = plot.minX + plot.width * 0.5
            } else {
                x = plot.minX + Float(clampedIndex) / Float(sampleCount - 1) * plot.width
            }
            list.addLine(fromX: x,
                         fromY: plot.minY,
                         toX: x,
                         toY: plot.maxY,
                         thickness: marker.width,
                         color: marker.color.resolve(theme))
        }
    }
}

public struct SparklineChart: View {
    public let values: [Float]
    public let color: SemanticColorRef
    public let threshold: ChartThreshold?
    public let marker: ChartMarker?
    public let style: ChartStyle

    public init(_ values: [Float],
                color: SemanticColorRef = .accent,
                threshold: ChartThreshold? = nil,
                marker: ChartMarker? = nil,
                style: ChartStyle = ChartStyle(gridLineCount: 2,
                                               contentInset: 3)) {
        self.values = values
        self.color = color
        self.threshold = threshold
        self.marker = marker
        self.style = style
    }

    public var body: some View {
        MonitorChart(values: values,
                     color: color,
                     mode: .line,
                     threshold: threshold,
                     marker: marker,
                     style: style)
    }
}

public struct BarChart: View {
    public let values: [Float]
    public let color: SemanticColorRef
    public let threshold: ChartThreshold?
    public let marker: ChartMarker?
    public let style: ChartStyle

    public init(_ values: [Float],
                color: SemanticColorRef = .accent,
                threshold: ChartThreshold? = nil,
                marker: ChartMarker? = nil,
                style: ChartStyle = ChartStyle()) {
        self.values = values
        self.color = color
        self.threshold = threshold
        self.marker = marker
        self.style = style
    }

    public var body: some View {
        MonitorChart(values: values,
                     color: color,
                     mode: .bar,
                     threshold: threshold,
                     marker: marker,
                     style: style)
    }
}

private struct ChartValueDomain {
    var min: Float
    var max: Float
}

private func chartValueDomain(series: [ChartSeries],
                              thresholds: [ChartThreshold],
                              style: ChartStyle) -> ChartValueDomain {
    var values: [Float] = series.flatMap { finiteValues($0.values) }
    values.append(contentsOf: thresholds.map(\.value).filter(\.isFinite))

    var minValue = style.minValue ?? values.min() ?? 0
    var maxValue = style.maxValue ?? values.max() ?? 1
    if !minValue.isFinite { minValue = 0 }
    if !maxValue.isFinite { maxValue = 1 }
    if minValue == maxValue {
        let pad = max(abs(minValue) * 0.1, 1)
        minValue -= pad
        maxValue += pad
    }
    if minValue > maxValue {
        swap(&minValue, &maxValue)
    }
    return ChartValueDomain(min: minValue, max: maxValue)
}

private func finiteValues(_ values: [Float]) -> [Float] {
    values.filter(\.isFinite)
}

private func chartY(value: Float,
                    plot: UIRect,
                    domain: ChartValueDomain) -> Float {
    let span = max(domain.max - domain.min, 0.001)
    let ratio = max(0, min((value - domain.min) / span, 1))
    return plot.maxY - ratio * plot.height
}

private func chartPoint(index: Int,
                        count: Int,
                        value: Float,
                        plot: UIRect,
                        domain: ChartValueDomain) -> (x: Float, y: Float) {
    let x: Float
    if count <= 1 {
        x = plot.minX + plot.width * 0.5
    } else {
        x = plot.minX + Float(index) / Float(count - 1) * plot.width
    }
    return (x, chartY(value: value, plot: plot, domain: domain))
}
