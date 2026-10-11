import GuavaUICompose
import GuavaUIRuntime

/// The gallery uses the same public surface and typography APIs as an app.
struct DashboardCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        ThemeReader { theme in
            Box(direction: .column, alignItems: .stretch, spacing: 16) { content }
                .padding(20).background(.surfaceRaised).cornerRadius(theme.radius.xl)
                .border(theme.colors.border.multipliedAlpha(0.55), width: 1)
                .shadow(color: theme.elevation.low.color ?? .clear, offsetY: 2, blur: 8)
        }
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let unit: String
    let detail: String
    let history: [Float]
    let tone: SemanticColorRef
    var body: some View {
        TextScalerReader { scaler in
            card.frame(minWidth: max(180, scaler.scale(180)), minHeight: 184)
                .flex(1, shrink: 1, basis: max(200, scaler.scale(180)))
        }
    }
    private var card: some View {
        DashboardCard {
            Text(title.uppercased()).font(.caption).letterSpacing(0.8).foregroundColor(.onSurfaceVariant)
            Row(alignment: .bottom, spacing: 5) {
                Text(value).font(.display).foregroundColor(.onSurface)
                Text(unit).font(.label).foregroundColor(.onSurfaceVariant).padding(vertical: 5)
            }
            if history.isEmpty { Spacer() }
            else {
                SparklineChart(history, color: tone, style: ChartStyle(minValue: 0, maxValue: 100, gridLineCount: 0, lineWidth: 2, contentInset: 2))
                    .frame(height: 42).accessibilityHidden()
            }
            Text(detail).font(.caption).foregroundColor(.onSurfaceMuted)
        }.debugName("dashboard-metric-\(title)")
    }
}
