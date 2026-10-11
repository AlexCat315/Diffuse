import GuavaUIRuntime

public struct TabItem<ID: Hashable>: Identifiable {
    public let id: ID
    public let label: String
    public let content: AnyView
    public var isEnabled: Bool
    /// Leading glyph. Tabs read faster with one, and it survives translation.
    public var icon: BundleImageResource?
    /// Short trailing count or status. Keep it to two or three characters.
    public var badge: String?
    /// When set the tab renders a close control. `nil` makes the tab permanent.
    public var onClose: (() -> Void)?

    public init<C: View>(_ label: String,
                         id: ID,
                         isEnabled: Bool = true,
                         configure: (inout Self) -> Void = { _ in },
                         @ViewBuilder content: () -> C) {
        self.id = id
        self.label = label
        self.content = AnyView(content())
        self.isEnabled = isEnabled
        configure(&self)
    }
}

/// Visual treatment of a `TabView` strip.
public enum TabVariant: Sendable, Hashable {
    /// Underlined document strip sitting flush with the content.
    case bar
    /// Single pill that selects a value rather than a document.
    case segmented
    /// Raised card for the active tab.
    case card
}

/// Which edge of a `TabView` holds the strip.
public enum TabStripPlacement: Sendable, Hashable {
    case top
    case bottom
}

/// What a `TabView` does when its tabs are wider than the strip.
public enum TabOverflow: Sendable, Hashable {
    /// Tabs wrap onto further lines. Safe, and the right default for a strip
    /// whose tab count grows at runtime.
    case wrap
    /// The strip scrolls horizontally. Use it when the strip must stay one line.
    case scroll
}

/// Multi-panel container with a single active panel.
///
/// Three variants cover the three places tabs realistically appear: `.bar` is a
/// document strip (editor panels, inspector pages), `.segmented` is a value
/// picker that happens to look like tabs, and `.card` is a folder metaphor for
/// content that sits on the same surface as the page.
///
/// The strip keeps one Tab stop for the whole group: arrows, Home and End move
/// between enabled tabs, and disabled tabs are skipped rather than announced as
/// unavailable one by one.
///
/// ```swift
/// TabView(selection: $page, tabs: tabs) { $0.variant = .card }
/// TabView(selection: $openFile, tabs: docs) { $0.overflow = .scroll }
/// ```
public struct TabView<ID: Hashable>: View {
    public typealias Variant = TabVariant
    public typealias Placement = TabStripPlacement
    public typealias Overflow = TabOverflow

    public var selection: Binding<ID>
    public var tabs: [TabItem<ID>]
    public var variant: TabVariant
    public var placement: TabStripPlacement
    public var overflow: TabOverflow
    public var isEnabled: Bool

    public init(selection: Binding<ID>,
                tabs: [TabItem<ID>],
                configure: (inout Self) -> Void = { _ in }) {
        self.selection = selection
        self.tabs = tabs
        self.variant = .bar
        self.placement = .top
        self.overflow = .wrap
        self.isEnabled = true
        configure(&self)
        precondition(Set(tabs.map(\.id)).count == tabs.count, "Tab IDs must be unique")
    }

    public var body: some View {
        let enabled = tabs.filter { isEnabled && $0.isEnabled }.map(\.id)
        let active = enabled.contains(selection.wrappedValue) ? selection.wrappedValue : enabled.first
        let tabStop = active ?? enabled.first
        return RovingFocusHost(
            enabledItems: enabled.map { AnyHashable($0) },
            // Read the binding at call time, not the `active` snapshot: two key
            // events can arrive inside one render pass, and a captured value
            // would send the second arrow from the previous selection.
            selection: { AnyHashable(selection.wrappedValue) },
            onSelect: { if let id = $0.base as? ID { selection.wrappedValue = id } }
        ) {
            Box(direction: .column, alignItems: .stretch, spacing: 0) {
                if placement == .top { strip(tabStop: tabStop) }
                contentArea
                if placement == .bottom { strip(tabStop: tabStop) }
            }
        }
    }

    @ViewBuilder private var contentArea: some View {
        if let active = tabs.first(where: { $0.id == selection.wrappedValue && $0.isEnabled }) {
            active.content.flex(1, shrink: 1, basis: 0).frame(minWidth: 0, minHeight: 0)
        }
    }

    private func strip(tabStop: ID?) -> some View {
        let items = Box(direction: .row,
                        alignItems: .center,
                        justifyContent: .flexStart,
                        wrap: overflow == .wrap ? .wrap : .noWrap,
                        spacing: variant == .segmented ? 2 : 0) {
            for tab in tabs {
                AnyView(_TabBarItem(label: tab.label,
                                    icon: tab.icon,
                                    badge: tab.badge,
                                    isSelected: tab.id == selection.wrappedValue,
                                    isEnabled: isEnabled && tab.isEnabled,
                                    variant: variant,
                                    indicator: indicatorPlacement,
                                    onSelect: { selection.wrappedValue = tab.id },
                                    onClose: tab.onClose)
                    .modifier(RovingItemModifier(id: AnyHashable(tab.id), isTabStop: tab.id == tabStop)))
            }
            Spacer()
        }
        let styled = variant == .segmented
            ? AnyView(items.padding(3).background(SemanticColorRef.surfaceVariant).cornerRadius(8))
            : AnyView(items.background(SemanticColorRef.surface))
        guard overflow == .scroll else { return styled }
        return AnyView(ScrollView(.horizontal) { styled }.frame(height: 40))
    }

    private var indicatorPlacement: IndicatorPlacement {
        guard variant == .bar else { return .none }
        return placement == .top ? .bottom : .top
    }
}

enum IndicatorPlacement: Sendable {
    case top, bottom, none
}

private struct _TabBarItem: View {
    let label: String
    let icon: BundleImageResource?
    let badge: String?
    let isSelected: Bool
    let isEnabled: Bool
    let variant: TabVariant
    let indicator: IndicatorPlacement
    let onSelect: () -> Void
    let onClose: (() -> Void)?

    var body: some View {
        Button(isEnabled: isEnabled, isSelected: isSelected, action: onSelect) {
            Row(alignment: .center, spacing: 6) {
                if let icon {
                    Icon(icon, size: .medium).accessibilityHidden()
                }
                Text(label).font(.label)
                if let badge {
                    Badge(badge) { $0.variant = .solid; $0.isEnabled = isEnabled }
                        .accessibilityHidden()
                }
                if let onClose {
                    Button(icon: .resource(UIIcons.Action.x),
                           size: 10,
                           isEnabled: isEnabled,
                           tooltip: "Close \(label)",
                           action: onClose)
                        .buttonStyle(.ghost)
                        .controlSize(.mini)
                        .accessibilityLabel("Close \(label)")
                }
            }
        }
        .buttonStyle(TabBarItemStyle(variant: variant, indicator: indicator))
        .accessibility {
            $0.role = .tab
            $0.state.isSelected = isSelected
        }
    }
}

/// Paints the tab surface and, for `.bar`, the active indicator.
///
/// The indicator is a real element rather than a border so it can sit on the
/// correct edge when the strip is placed below the content, and so an inactive
/// tab still reserves the same two pixels — selecting a tab never shifts the
/// label.
private struct TabBarItemStyle: ButtonStyle {
    let variant: TabVariant
    let indicator: IndicatorPlacement

    func makeBody(configuration c: ButtonStyleConfiguration) -> some View {
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            if indicator == .top { AnyView(indicatorView(c)) }
            AnyView(surface(c))
            if indicator == .bottom { AnyView(indicatorView(c)) }
        }
    }

    private func surface(_ c: ButtonStyleConfiguration) -> some View {
        let theme = c.theme
        let disabledInk = theme.textEmphasis.disabled ?? theme.colors.onSurfaceMuted
        let style = resolvedStyle(c, theme: theme, disabledInk: disabledInk)
        return Row(alignment: .center) { AnyView(c.label) }
            .padding(horizontal: style.paddingX, vertical: 7)
            .foregroundColor(style.ink)
            .background(style.fill)
            .cornerRadius(style.radius)
            .border(c.isFocused ? theme.colors.focusRing : .clear, width: c.isFocused ? 2 : 0)
    }

    private func resolvedStyle(_ c: ButtonStyleConfiguration,
                               theme: Theme,
                               disabledInk: Color) -> Style {
        let ink = c.isEnabled ? (c.isSelected ? theme.colors.onSurface : theme.colors.onSurfaceVariant) : disabledInk
        switch variant {
        case .bar:
            return Style(ink: ink,
                         fill: !c.isEnabled ? .clear
                            : c.isPressed ? theme.colors.stateLayerPressed
                            : c.isHovered ? theme.colors.stateLayerHover
                            : .clear,
                         radius: theme.radius.sm,
                         paddingX: 14)
        case .segmented:
            return Style(ink: ink,
                         fill: !c.isEnabled ? .clear
                            : c.isSelected ? theme.colors.surfaceRaised
                            : c.isPressed ? theme.colors.stateLayerPressed
                            : c.isHovered ? theme.colors.stateLayerHover
                            : .clear,
                         radius: theme.radius.sm,
                         paddingX: 12)
        case .card:
            return Style(ink: ink,
                         fill: !c.isEnabled ? .clear
                            : c.isSelected ? theme.colors.surfaceRaised
                            : c.isHovered ? theme.colors.stateLayerHover
                            : .clear,
                         radius: theme.radius.md,
                         paddingX: 14)
        }
    }

    private func indicatorView(_ c: ButtonStyleConfiguration) -> some View {
        Divider(color: c.isSelected ? c.theme.colors.accent : .clear, thickness: 2, axis: .horizontal)
    }

    private struct Style {
        let ink: Color
        let fill: Color
        let radius: Float
        let paddingX: Float
    }
}
