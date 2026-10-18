import GuavaUIRuntime

/// One definition of "this row is selected", shared by every selectable surface.
///
/// Styles used to re-derive their fill and corner treatment straight from raw
/// theme colours, so a list row, a tree row, a table row and a sidebar item
/// each ended up looking like a different component. A style still chooses a
/// *role* — that is what says why a surface looks the way it does — but the
/// colours and the geometry of each role live here and nowhere else, so a new
/// row style inherits the house selection instead of inventing one.
///
/// Three roles, because the surfaces answer different questions:
///
/// - `sidebar`: the iOS/macOS source list pill. A neutral grouped fill keeps
///   the selected destination quiet; the accent is reserved for controls.
/// - `navigation`: an accent-tinted pill for tabs and compact navigation.
/// - `dataRow`: an edge-to-edge band, for dense grids whose rows share
///   horizontal rules with their neighbours and must keep column alignment.
///
/// Hover/press are state layers on top of the resting fill, so a selected row
/// still answers the pointer without turning into a second accent colour.
public struct SelectionAppearance: Equatable, Sendable {
    public enum Role: Sendable, Equatable {
        case sidebar
        case navigation
        case dataRow
    }

    /// Fill of the resting selection.
    public let fill: Color
    public let hoverFill: Color
    public let pressedFill: Color
    /// 0 paints an edge-to-edge band; anything else rounds the highlight.
    public let cornerRadius: Float
    /// Canvas the caller keeps clear on the leading and trailing edge, so the
    /// pill does not touch the row it belongs to.
    public let horizontalInset: Float
    /// Canvas kept clear above and below the highlight.
    public let verticalInset: Float

    public static func resolve(_ role: Role, theme: Theme) -> SelectionAppearance {
        let colors = theme.colors
        let insetRole = role != .dataRow
        return SelectionAppearance(fill: role == .sidebar ? colors.surfaceVariant : colors.selection,
                                   hoverFill: colors.stateLayerHover,
                                   pressedFill: colors.stateLayerPressed,
                                   cornerRadius: insetRole ? theme.radius.md : 0,
                                   horizontalInset: insetRole ? theme.spacing.sm : 0,
                                   verticalInset: insetRole ? theme.spacing.xs : 0)
    }

    /// The fill for one interaction state. Selection is a resting state, not a
    /// replacement for feedback: a selected row still answers hover and press.
    public func fill(isSelected: Bool, isHovered: Bool, isPressed: Bool) -> Color {
        if isPressed { return isSelected ? pressedFill.composited(over: fill) : pressedFill }
        if isHovered { return isSelected ? hoverFill.composited(over: fill) : hoverFill }
        return isSelected ? fill : .clear
    }
}

public extension View {
    /// Paints the shared selection behind this view.
    ///
    /// Every selectable style routes its background through here, which is what
    /// keeps a list row and a sidebar item from drifting apart. The insets are
    /// exposed rather than applied: a surface that owns a full-height row needs
    /// the highlight floated inside it, while a surface whose rows are their own
    /// highlight only needs the colour and the radius.
    func selectionHighlight(_ role: SelectionAppearance.Role,
                            isSelected: Bool,
                            isHovered: Bool = false,
                            isPressed: Bool = false) -> some View {
        ThemeReader { theme in
            let appearance = SelectionAppearance.resolve(role, theme: theme)
            return self
                .background(appearance.fill(isSelected: isSelected,
                                            isHovered: isHovered,
                                            isPressed: isPressed))
                .cornerRadius(appearance.cornerRadius)
        }
    }
}