import GuavaUIRuntime

/// Line, area, bar, scatter and pie/donut charts with an optional legend and
/// point selection.
///
/// ```swift
/// Chart([.area(revenue, title: "Revenue"), .bar(orders, color: .success, title: "Orders")],
///       thresholds: [ChartThreshold(value: 30)]) {
///     $0.selection.point = $selected
///     $0.legend.placement = .bottom
/// }
/// .frame(height: 180)
///
/// Chart(slices: [ChartSlice("Desktop", value: 58), ChartSlice("Mobile", value: 31)]) {
///     $0.legend.placement = .bottom
/// }
/// ```
///
/// Width follows the parent; the plot takes the height left after the legend
/// (64pt when unconstrained). Selection is interactive only with a binding:
/// hover previews on pointer surfaces, click/tap pins, drag scrubs, arrows
/// step, Escape clears. Legend items toggle series visibility.
public struct Chart: View {
    private let content: ChartContent
    private let style: ChartStyle
    private let configuration: ChartConfiguration
    @State private var ownHidden: Set<String> = []

    public init(_ series: [ChartSeries],
                thresholds: [ChartThreshold] = [],
                markers: [ChartMarker] = [],
                style: ChartStyle = ChartStyle(),
                configure: (inout ChartConfiguration) -> Void = { _ in }) {
        self.init(.cartesian(series: series, thresholds: thresholds, markers: markers), style: style, configure: configure)
    }

    public init(slices: [ChartSlice],
                style: ChartStyle = ChartStyle(gridLineCount: 0),
                configure: (inout ChartConfiguration) -> Void = { _ in }) {
        self.init(.pie(slices), style: style, configure: configure)
    }

    private init(_ content: ChartContent, style: ChartStyle, configure: (inout ChartConfiguration) -> Void) {
        var configuration = ChartConfiguration()
        configure(&configuration)
        self.content = content
        self.style = style
        self.configuration = configuration
    }

    public var body: some View {
        let hidden = hiddenBinding
        let visible = (0..<content.count).map { index in
            let title = content.title(index)
            return title.isEmpty || !hidden.wrappedValue.contains(title)
        }
        let point = configuration.selection.point
        let selection = point?.wrappedValue.flatMap { visible.indices.contains(visibleIndex($0)) && visible[visibleIndex($0)] ? $0 : nil }
        Box(direction: .column, alignItems: .stretch, spacing: 10) {
            ChartPlot(content: content, visible: visible, style: style, selection: selection,
                      summary: summary(visible: visible, selection: selection),
                      callout: selection.flatMap { callout(for: $0) },
                      input: ChartPlotInput(isEnabled: point != nil) { next in
                          if point?.wrappedValue != next { point?.wrappedValue = next }
                      })
                .flex(1, shrink: 1)
            if configuration.legend.placement == .bottom {
                ChartLegend(items: legendItems, hidden: hidden).flex(0, shrink: 0)
            }
        }
        .frame(minWidth: 0)
    }

    /// The legend index a selection belongs to: its series, or its slice.
    private func visibleIndex(_ point: ChartPoint) -> Int {
        if case .pie = content { return point.index }
        return point.series
    }

    private var hiddenBinding: Binding<Set<String>> {
        if let binding = configuration.legend.hiddenSeries { return binding }
        return $ownHidden
    }

    private var legendItems: [ChartLegendItem] {
        switch content {
        case .cartesian(let series, _, _):
            series.compactMap { $0.title.isEmpty ? nil : ChartLegendItem(title: $0.title, color: $0.color) }
        case .pie(let slices):
            slices.indices.map { ChartLegendItem(title: slices[$0].title, color: slices[$0].resolvedColor(at: $0)) }
        }
    }

    private func value(at point: ChartPoint) -> (title: String, value: Float)? {
        switch content {
        case .cartesian(let series, _, _):
            guard series.indices.contains(point.series), series[point.series].values.indices.contains(point.index) else { return nil }
            return (series[point.series].title, series[point.series].values[point.index])
        case .pie(let slices):
            guard slices.indices.contains(point.index) else { return nil }
            return (slices[point.index].title, slices[point.index].value)
        }
    }

    private func callout(for point: ChartPoint) -> ChartCallout? {
        guard let entry = value(at: point) else { return nil }
        let format = configuration.selection.valueText
        var detail = format(entry.value)
        if case .pie(let slices) = content {
            let total = slices.map { max(0, $0.value) }.reduce(0, +)
            if total > 0 { detail += " · \(Int((entry.value / total * 100).rounded()))%" }
        }
        let title = entry.title.isEmpty ? (content.isPie ? "Slice \(point.index + 1)" : "Point \(point.index + 1)") : entry.title
        return ChartCallout(point: point, title: title, value: detail)
    }

    private func summary(visible: [Bool], selection: ChartPoint?) -> (label: String, value: String) {
        let format = configuration.selection.valueText
        if let selection, let callout = callout(for: selection) {
            let position = content.isPie ? "" : ", point \(selection.index + 1)"
            return (configuration.label, "\(callout.title)\(position): \(callout.value)")
        }
        switch content {
        case .cartesian(let series, _, _):
            let shown = series.indices.filter { visible[$0] && !series[$0].values.isEmpty }
            let parts = shown.map { index -> String in
                let values = series[index].values.filter(\.isFinite)
                let name = series[index].title.isEmpty ? "Series \(index + 1)" : series[index].title
                return "\(name) \(format(values.min() ?? 0)) to \(format(values.max() ?? 0))"
            }
            return (configuration.label, parts.isEmpty ? "No data" : parts.joined(separator: "; "))
        case .pie(let slices):
            let parts = slices.indices.filter { visible[$0] }.map { "\(slices[$0].title) \(format(slices[$0].value))" }
            return (configuration.label, parts.isEmpty ? "No data" : parts.joined(separator: "; "))
        }
    }
}

extension ChartContent {
    var isPie: Bool {
        if case .pie = self { return true }
        return false
    }
}

/// The floating label for the selected value.
struct ChartCallout: Equatable {
    let point: ChartPoint
    let title: String
    let value: String
}
