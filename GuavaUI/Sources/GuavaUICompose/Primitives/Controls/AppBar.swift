private import Foundation
private import GuavaUIRuntime

public struct AppBarOptions {
    public var isEnabled = true
    public var label = "Application bar"
    public var compactMaximumWidth = UIEnvironment.Viewport.compactMaximumWidth
    public var divider = ToolbarDividerEdge.bottom
    public init() {}
    mutating func validate() {
        compactMaximumWidth = compactMaximumWidth.isFinite ? max(0, compactMaximumWidth) : 600
    }
}

/// A bounded application header. The host owns safe-area insets; the bar owns
/// a full-name heading, back action and at most one/three inline commands.
public struct AppBar: View {
    private let title: String
    private let subtitle: String?
    private let back: MenuItem?
    private let primary: ToolbarItem?
    private let actions: [ToolbarItem]
    private let options: AppBarOptions
    @State private var commandWidth: Float? = nil

    public init(_ title: String, subtitle: String? = nil, back: MenuItem? = nil,
                primary: ToolbarItem? = nil, actions: [ToolbarItem] = [],
                configure: (inout AppBarOptions) -> Void = { _ in }) {
        self.title = title; self.subtitle = subtitle; self.back = back; self.primary = primary; self.actions = actions
        var options = AppBarOptions(); configure(&options)
        options.validate()
        self.options = options
        let ids = (primary.map { [$0] } ?? []) + actions
        precondition(Set(ids.map(\.command.id)).count == ids.count, "AppBar command IDs must be unique")
    }

    public var body: some View {
        SurfaceReader { surface in
            ThemeReader { theme in
                TextScalerReader { scaler in
                    ContainerSizeReader { size in
                        let width = size.width > 0 ? Float(size.width) : surface.viewport.width
                        let compact = width < options.compactMaximumWidth
                        let items = commands(compact: compact)
                        let gap = theme.spacing.xs
                        let available = max(0, width - theme.spacing.sm * 2 - (back == nil ? 0 : 44) - gap * (back == nil ? 1 : 2))
                        let primaryWidth: Float = primary == nil ? 0 : primary?.icon == nil ? max(44, scaler.scale(48) + 32) : 44
                        let required = primaryWidth + (items.count > (primary == nil ? 0 : 1) ? 44 : 0)
                            + (primary != nil && items.count > 1 ? gap : 0)
                        let budget = max(0, available - min(scaler.scale(96), max(0, available - required)))
                        ToolbarHost(options: toolbarOptions, content: contents(items: items, compact: compact,
                            budget: budget, gap: gap, scaler: scaler), chrome: .init(minimumHeight: 48, verticalPadding: 2))
                    }
                }
            }
        }
    }

    private var toolbarOptions: ToolbarOptions {
        var result = ToolbarOptions(); result.isEnabled = options.isEnabled
        result.divider = options.divider; result.label = options.label
        return result
    }

    @ViewBuilder private func contents(items: [ToolbarItem], compact: Bool, budget: Float, gap: Float, scaler: TextScaler) -> some View {
        if let back {
            AppBarBack(command: back, isEnabled: options.isEnabled).id(back.id)
        }
        Box(direction: .column, alignItems: .stretch, spacing: 2) {
            Text(title).truncated().font(.bodyStrong).foregroundColor(.onSurface)
                .accessibility { $0.role = .heading; $0.label = title; $0.value = compact ? subtitle ?? "" : ""; $0.combinesChildren = true }
            if !compact, let subtitle, !subtitle.isEmpty {
                Text(subtitle).truncated().font(.caption).foregroundColor(.onSurfaceMuted)
            }
        }.flex(1, shrink: 1, basis: 0).frame(minWidth: 0)
        ToolbarCommands(items: items, isEnabled: options.isEnabled, availableWidth: CGFloat(budget),
            presentation: .init(minimumExtent: 44,
                maximumButtonWidth: max(0, min(scaler.scale(120) + 32, budget - (items.count > 1 ? 44 + gap : 0))),
                usesOverflowIcon: true), onContentWidth: { measured in
                    let next = Float(measured)
                    if commandWidth != next { commandWidth = next }
                })
            .frame(width: min(commandWidth ?? budget, budget)).flex(0, shrink: 0).iconScaling(.fixed)
    }

    private func commands(compact: Bool) -> [ToolbarItem] {
        let capacity = max(0, (compact ? 1 : 3) - (primary == nil ? 0 : 1))
        let candidates = actions.indices.filter { actions[$0].placement != .overflow }.sorted {
            let a = actions[$0].placement.priority, b = actions[$1].placement.priority
            return a == b ? $0 < $1 : a > b
        }
        let inline = Set(candidates.prefix(capacity))
        var result: [ToolbarItem] = primary.map { [ToolbarItem($0.command, icon: $0.icon, placement: .always)] } ?? []
        result += actions.enumerated().map { index, item in
            ToolbarItem(item.command, icon: item.icon, placement: inline.contains(index) ? .automatic(priority: item.placement.priority) : .overflow)
        }
        return result
    }
}

private extension ToolbarItem.Placement {
    var priority: Int {
        switch self {
        case .always: Int.max
        case .automatic(let value): value
        case .overflow: Int.min
        }
    }
}
