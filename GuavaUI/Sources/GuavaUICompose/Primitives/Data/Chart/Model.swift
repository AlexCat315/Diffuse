import GuavaUIRuntime

/// How a series is drawn. Marks can be mixed in one chart; when any series
/// uses bars, every mark is centered on the bar slots so they line up.
public enum ChartMark: Sendable, Equatable {
    case line
    /// A line over a translucent fill down to the baseline (or the series below when stacked).
    case area
    case bar
    /// Unconnected points; with `xValues` this is a scatter plot.
    case point
}

public struct ChartSeries: Sendable {
    public var values: [Float]
    /// Optional numeric x positions (scatter). Without them, values are evenly spaced by index.
    public var xValues: [Float]?
    public var color: SemanticColorRef
    public var mark: ChartMark
    /// Legend and selection name. An empty title keeps the series out of the legend.
    public var title: String

    public init(values: [Float], xValues: [Float]? = nil, color: SemanticColorRef = .accent,
                mark: ChartMark = .line, title: String = "") {
        self.values = values
        self.xValues = xValues
        self.color = color
        self.mark = mark
        self.title = title
    }

    public static func line(_ values: [Float], color: SemanticColorRef = .accent, title: String = "") -> ChartSeries {
        ChartSeries(values: values, color: color, mark: .line, title: title)
    }

    public static func area(_ values: [Float], color: SemanticColorRef = .accent, title: String = "") -> ChartSeries {
        ChartSeries(values: values, color: color, mark: .area, title: title)
    }

    public static func bar(_ values: [Float], color: SemanticColorRef = .accent, title: String = "") -> ChartSeries {
        ChartSeries(values: values, color: color, mark: .bar, title: title)
    }

    /// A scatter series; `x` and `y` are paired by index and truncated to the shorter one.
    public static func points(x: [Float], y: [Float], color: SemanticColorRef = .accent, title: String = "") -> ChartSeries {
        let count = min(x.count, y.count)
        return ChartSeries(values: Array(y.prefix(count)), xValues: Array(x.prefix(count)),
                           color: color, mark: .point, title: title)
    }
}

/// One part of a pie or donut chart. Without a color, slices take the
/// categorical palette in order.
public struct ChartSlice: Sendable {
    public var value: Float
    public var title: String
    public var color: SemanticColorRef?

    public init(_ title: String, value: Float, color: SemanticColorRef? = nil) {
        self.title = title
        self.value = value
        self.color = color
    }
}

public struct ChartThreshold: Sendable {
    public var value: Float
    public var color: SemanticColorRef

    public init(value: Float, color: SemanticColorRef = .warning) {
        self.value = value
        self.color = color
    }
}

public struct ChartMarker: Sendable {
    public var index: Int
    public var color: SemanticColorRef
    public var width: Float

    public init(index: Int, color: SemanticColorRef = .accent, width: Float = 1) {
        self.index = index
        self.color = color
        self.width = max(width, 1)
    }
}

/// Whether bar and area series accumulate per index.
public enum ChartStacking: Sendable, Equatable {
    case none
    case stacked
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
    public var stacking: ChartStacking
    /// Donut hole as a fraction of the radius; 0 draws a full pie.
    public var innerRadiusRatio: Float

    public init(minValue: Float? = nil,
                maxValue: Float? = nil,
                gridLineCount: Int = 4,
                lineWidth: Float = 2,
                barSpacing: Float = 2,
                contentInset: Float = 4,
                background: SemanticColorRef? = nil,
                gridColor: SemanticColorRef = .divider,
                stacking: ChartStacking = .none,
                innerRadiusRatio: Float = 0.6) {
        self.minValue = minValue
        self.maxValue = maxValue
        self.gridLineCount = max(0, gridLineCount)
        self.lineWidth = max(lineWidth, 0.5)
        self.barSpacing = max(barSpacing, 0)
        self.contentInset = max(contentInset, 0)
        self.background = background
        self.gridColor = gridColor
        self.stacking = stacking
        self.innerRadiusRatio = min(max(innerRadiusRatio.isFinite ? innerRadiusRatio : 0, 0), 0.9)
    }

    /// A compact trend line: two grid lines and a small inset.
    public static var sparkline: ChartStyle { ChartStyle(gridLineCount: 2, lineWidth: 1.5, contentInset: 3) }
}

/// A selected value: the series index (or 0 for a pie) and the value index (or slice).
public struct ChartPoint: Hashable, Sendable {
    public var series: Int
    public var index: Int

    public init(series: Int, index: Int) {
        self.series = series
        self.index = index
    }
}

/// Interactive behavior, configured in `Chart(...) { $0.selection.point = $point }`.
public struct ChartConfiguration {
    public struct Selection {
        /// Enables hover, tap/drag scrubbing, keyboard and assistive selection.
        public var point: Binding<ChartPoint?>?
        /// Formats values in the callout and accessibility value.
        public var valueText: (Float) -> String = { value in
            value.rounded() == value && abs(value) < 1e9 ? String(Int(value)) : String(format: "%.2f", value)
        }
    }

    public struct Legend {
        public enum Placement: Sendable, Equatable { case hidden, bottom }
        public var placement: Placement = .hidden
        /// Titles of hidden series. Legend items toggle membership; without a
        /// binding the chart keeps the hidden set itself.
        public var hiddenSeries: Binding<Set<String>>?
    }

    public var selection = Selection()
    public var legend = Legend()
    /// Accessible name of the chart.
    public var label = "Chart"

    public init() {}
}

extension ChartSlice {
    /// Distinct hues first; `info` is a second blue in the default themes, so it comes last.
    static let palette: [SemanticColorRef] = [.accent, .success, .warning, .accentSecondary, .error, .info]
    func resolvedColor(at index: Int) -> SemanticColorRef { color ?? Self.palette[index % Self.palette.count] }
}
