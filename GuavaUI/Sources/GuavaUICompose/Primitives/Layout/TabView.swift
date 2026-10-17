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
    /// Bottom on compact surfaces; top on medium and expanded surfaces.
    case adaptive
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
    /// Keep the selected tab in the strip and list hidden tabs in a menu.
    case menu
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
    public var variant: TabVariant = .bar
    public var placement: TabStripPlacement = .adaptive
    public var overflow: TabOverflow = .wrap
    public var isEnabled = true
    @State private var focusRequest = RovingFocusRequest()

    public init(selection: Binding<ID>,
                tabs: [TabItem<ID>],
                configure: (inout Self) -> Void = { _ in }) {
        self.selection = selection
        self.tabs = tabs
        configure(&self)
        precondition(Set(tabs.map(\.id)).count == tabs.count, "Tab IDs must be unique")
    }

    public var body: some View {
        let enabled = tabs.filter { isEnabled && $0.isEnabled }.map(\.id)
        let active = enabled.contains(selection.wrappedValue) ? selection.wrappedValue : enabled.first
        let tabStop = active ?? enabled.first
        return SurfaceReader { surface in
            let placement = self.placement == .adaptive ? (surface.viewport.widthClass == .compact ? TabStripPlacement.bottom : .top) : self.placement
            RovingFocusHost(
                enabledItems: enabled.map { AnyHashable($0) },
                // Read the binding at call time, not the `active` snapshot: two key
                // events can arrive inside one render pass, and a captured value
                // would send the second arrow from the previous selection.
                selection: { AnyHashable(selection.wrappedValue) },
                onSelect: { if let id = $0.base as? ID { selection.wrappedValue = id } },
                focusRequest: focusRequest
            ) {
                Box(direction: placement == .top ? .column : .columnReverse, alignItems: .stretch, spacing: 0) {
                    strip(tabStop: tabStop, placement: placement, surface: surface)
                    contentArea
                }
            }
        }
    }

    @ViewBuilder private var contentArea: some View {
        if let active = tabs.first(where: { $0.id == selection.wrappedValue && $0.isEnabled }) {
            active.content.id(active.id).flex(1, shrink: 1, basis: 0).frame(minWidth: 0, minHeight: 0)
        }
    }

    private func strip(tabStop: ID?, placement: TabStripPlacement, surface: UIEnvironment) -> some View {
        ContainerSizeReader { size in
            let indicator: IndicatorPlacement = variant == .bar ? (placement == .top ? .bottom : .top) : .none
            let items: AnyView
            if overflow == .menu {
                items = AnyView(TabOverflowStrip(tabs: tabs, selection: selection, tabStop: tabStop,
                    isEnabled: isEnabled, variant: variant, indicator: indicator, focusRequest: focusRequest))
            } else {
                items = AnyView(Box(direction: .row,
                                alignItems: .center,
                                justifyContent: .flexStart,
                                wrap: overflow == .wrap ? .wrap : .noWrap,
                                spacing: variant == .segmented ? 2 : 0) {
                    for tab in tabs {
                        AnyView(TabStripItem(tab: tab, selection: selection, isEnabled: isEnabled,
                                            variant: variant, indicator: indicator, tabStop: tabStop,
                                            maximumWidth: size.width > 0 ? Float(max(44, size.width - (variant == .segmented ? 6 : 0))) : .greatestFiniteMagnitude)
                            .id(tab.id))
                    }
                    Spacer()
                })
            }
            let segmented = variant == .segmented
            let styled = AnyView(items.padding(segmented ? 3 : 0)
                .background(segmented ? SemanticColorRef.surfaceVariant : .surface)
                .cornerRadius(ThemeMetric { segmented ? $0.radius.md : 0 }))
            guard overflow == .scroll else { return styled }
            let height = max(Float(40), surface.input.contains(.touch) ? surface.minimumControlExtent + (variant == .segmented ? 6 : 0) : 0)
            return AnyView(ScrollView(.horizontal) { styled }.frame(minHeight: height).flex(0, shrink: 0))
        }
    }
}

enum IndicatorPlacement: Sendable {
    case top, bottom, none
}

struct TabStripItem<ID: Hashable>: View {
    let tab: TabItem<ID>
    let selection: Binding<ID>
    let isEnabled: Bool
    let variant: TabVariant
    let indicator: IndicatorPlacement
    let tabStop: ID?
    var maximumWidth: Float = .greatestFiniteMagnitude
    @State private var chromeWidth: Float = 0

    var body: some View {
        let enabled = isEnabled && tab.isEnabled
        let minimumWidth = max(44, chromeWidth + variant.horizontalPadding * 2)
        return Button(isEnabled: enabled, isSelected: tab.id == selection.wrappedValue,
                      tooltip: tab.label, action: { selection.wrappedValue = tab.id }) {
            TabLabelLayout(onMinimumWidth: { width in
                if chromeWidth != Float(width) { chromeWidth = Float(width) }
            }) {
                Box(direction: .row, spacing: 0) {
                    if let icon = tab.icon { Icon(icon, size: .medium).accessibilityHidden() }
                }
                Text(tab.label).truncatingTail().font(.label).accessibilityHidden()
                Row(alignment: .center, spacing: 6) {
                    if let badge = tab.badge {
                        Badge(badge) { $0.variant = .solid; $0.isEnabled = enabled }
                            .flex(0, shrink: 0).accessibilityHidden()
                    }
                    if let onClose = tab.onClose {
                        Button(icon: .resource(UIIcons.Action.x),
                               size: 10,
                               isEnabled: enabled,
                               tooltip: "Close \(tab.label)",
                               action: onClose)
                            .buttonStyle(.ghost)
                            .controlSize(.mini)
                            .flex(0, shrink: 0).accessibilityLabel("Close \(tab.label)")
                    }
                }
            }
        }
        .buttonStyle(TabBarItemStyle(variant: variant, indicator: indicator))
        .compositionLocal(ActionControlAccessibility.label, tab.label)
        .modifier(RovingItemModifier(id: AnyHashable(tab.id), isTabStop: tab.id == tabStop))
        .frame(minWidth: minimumWidth, maxWidth: max(minimumWidth, maximumWidth))
        .accessibility {
            $0.role = .tab
            $0.label = tab.label
            $0.state.isSelected = tab.id == selection.wrappedValue
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
        return Box(direction: .column, alignItems: .stretch) { AnyView(c.label) }
            .padding(horizontal: variant.horizontalPadding, vertical: 7)
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
                         radius: theme.radius.sm)
        case .segmented:
            return Style(ink: ink,
                         fill: !c.isEnabled ? .clear
                            : c.isSelected ? theme.colors.surfaceRaised
                            : c.isPressed ? theme.colors.stateLayerPressed
                            : c.isHovered ? theme.colors.stateLayerHover
                            : .clear,
                         radius: theme.radius.sm)
        case .card:
            return Style(ink: ink,
                         fill: !c.isEnabled ? .clear
                            : c.isSelected ? theme.colors.surfaceRaised
                            : c.isHovered ? theme.colors.stateLayerHover
                            : .clear,
                         radius: theme.radius.md)
        }
    }

    private func indicatorView(_ c: ButtonStyleConfiguration) -> some View {
        Divider(color: c.isSelected ? c.theme.colors.accent : .clear, thickness: 2, axis: .horizontal)
    }

    private struct Style {
        let ink: Color
        let fill: Color
        let radius: Float
    }
}
