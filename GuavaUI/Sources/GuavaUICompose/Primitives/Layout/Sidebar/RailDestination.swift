import GuavaUIRuntime

struct RailDestinationLabel<ID: Hashable>: View {
    let item: SidebarItem<ID>
    let showsLabels: Bool
    let iconExtent: Float
    var isExpanded: Bool? = nil

    var body: some View {
        Box(direction: .column, alignItems: .center, spacing: 4) {
            Box(direction: .column, alignItems: .center, justifyContent: .center) {
                // Extent has already resolved icon roles and scaling. Preserve
                // replacements while avoiding a second application of scaling.
                Icon(item.icon ?? UIIcons.File.file, size: iconExtent).iconScaling(.fixed).accessibilityHidden()
                if item.badge != nil {
                    Box {}.frame(width: 6, height: 6).background(item.isEnabled ? .accent : .onSurfaceDisabled)
                        .cornerRadius(3).absolutePosition(top: 0, right: 0).accessibilityHidden()
                }
                if let isExpanded {
                    Icon(isExpanded ? UIIcons.Action.minus : UIIcons.Action.plus, size: 10)
                        .background(.surface).accessibilityHidden().absolutePosition(top: -4, right: -7)
                }
            }.frame(width: iconExtent, height: iconExtent).flex(0, shrink: 0)
            if showsLabels {
                Text(item.title, alignment: .center).font(.caption).frame(width: .percent(100))
                    .debugName("sidebar-title-\(item.id)")
            }
        }.frame(width: .percent(100), minWidth: 0)
    }
}

/// The icon-only rail paints one compact, centered tile instead of a
/// full-width band. The button keeps the whole row as its hit target; only the
/// visible highlight shrinks to a square around the glyph.
private let railIconTileExtent: Float = 40

struct RailDestinationStyle: ButtonStyle {
    let minimumHeight: Float
    var showsLabels: Bool = true

    func makeBody(configuration c: ButtonStyleConfiguration) -> AnyView {
        let theme = c.theme
        let foreground: SemanticColorRef = !c.isEnabled
            ? .onSurfaceDisabled
            : (c.isSelected || c.isHovered ? .onSurface : .onSurfaceVariant)
        let focus = c.isFocused ? theme.colors.focusRing : Color(r: 0, g: 0, b: 0, a: 0)
        let focusWidth: Float = c.isFocused ? 1 : 0

        if showsLabels {
            // The whole row is the pill when labels are visible, so the icon
            // and its wrapped title share one aligned surface. Symmetric
            // padding replaces the old leading accent lane.
            return AnyView(
                Box(direction: .row, alignItems: .center, justifyContent: .center) {
                    AnyView(c.label).flex(1, shrink: 1, basis: 0).frame(minWidth: 0)
                }
                .padding(horizontal: 6, vertical: 8)
                .frame(width: .percent(100), minHeight: minimumHeight)
                .foregroundColor(foreground)
                .selectionHighlight(.sidebar, isSelected: c.isSelected,
                                    isHovered: c.isHovered, isPressed: c.isPressed)
                .border(focus, width: focusWidth)
                .animation(.semantic(.fast, in: theme), value: c.interactionKey)
            )
        }

        let appearance = SelectionAppearance.resolve(.sidebar, theme: theme)
        let fill = appearance.fill(isSelected: c.isSelected,
                                   isHovered: c.isHovered,
                                   isPressed: c.isPressed)
        return AnyView(
            Box(direction: .row, alignItems: .center, justifyContent: .center) {
                Box(direction: .column, alignItems: .stretch, justifyContent: .center) {
                    AnyView(c.label)
                }
                .frame(width: railIconTileExtent, height: railIconTileExtent)
                .foregroundColor(foreground)
                .background(fill)
                .cornerRadius(appearance.cornerRadius)
                .border(focus, width: focusWidth)
                .animation(.semantic(.fast, in: theme), value: c.interactionKey)
                .debugName("rail-selection-tile")
            }
            .frame(width: .percent(100), minHeight: minimumHeight)
        )
    }
}
