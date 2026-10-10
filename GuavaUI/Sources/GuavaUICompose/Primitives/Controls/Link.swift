import GuavaUIRuntime

/// When a link draws its underline.
///
/// The choice is contextual rather than decorative: in body copy the link has
/// to be identifiable before the pointer arrives, while in a dense tool panel
/// a permanent underline turns every row into visual noise.
public enum LinkUnderline: Sendable, Hashable {
    /// Always underlined — body copy, help text, license notices.
    case always
    /// Underlined on hover and keyboard focus — tool panels, tables, toolbars.
    case hover
    /// Never underlined; colour alone carries the affordance. Only defensible
    /// where the surrounding text is clearly not interactive.
    case never
}

/// A navigation or command target rendered inside text.
///
/// A link is not a button with a tint: it stays in the reading flow, so it
/// inherits the surrounding type size, keeps no chrome of its own until the
/// pointer or focus arrives, and always announces itself as a link rather than
/// as a button.
///
/// ```swift
/// Text("Licensed under ")
/// + Link("Apache 2.0", isExternal: true) { openLicense() }
///
/// Link("Reset layout", underline: .hover) { reset() }
/// ```
public struct Link<Label: View>: View {
    public let label: Label
    public let action: () -> Void
    public var isEnabled: Bool
    public var isExternal: Bool
    public var underline: LinkUnderline
    /// Overrides the trailing glyph. `nil` falls back to the external-link
    /// arrow when `isExternal` is set.
    public var icon: BundleImageResource?
    public var tooltip: String?

    public init(tooltip: String? = nil,
                action: @escaping () -> Void,
                configure: (inout Self) -> Void = { _ in },
                @ViewBuilder label: () -> Label) {
        self.tooltip = tooltip
        self.action = action
        self.label = label()
        self.isEnabled = true
        self.isExternal = false
        self.underline = .always
        self.icon = nil
        configure(&self)
    }

    public var body: some View {
        Button(isEnabled: isEnabled, tooltip: tooltip, action: action) {
            Row(alignment: .center, spacing: 4) {
                label
                if let icon {
                    Icon(icon, size: 12)
                } else if isExternal {
                    Icon(UIIcons.Action.externalLink, size: 12)
                }
            }
        }
        .buttonStyle(LinkStyle(underline: underline))
        .accessibility { $0.role = .link }
    }
}

public extension Link where Label == Text {
    init(_ title: String,
         isEnabled: Bool = true,
         tooltip: String? = nil,
         configure: (inout Self) -> Void = { _ in },
         action: @escaping () -> Void) {
        self.init(tooltip: tooltip, action: action) {
            Text(title)
        }
        self.isEnabled = isEnabled
        configure(&self)
    }
}

private struct LinkStyle: ButtonStyle {
    var underline: LinkUnderline

    func makeBody(configuration c: ButtonStyleConfiguration) -> some View {
        let resting = c.isEnabled ? c.theme.colors.accent : c.theme.colors.onSurfaceMuted
        let ink = c.isPressed ? c.theme.colors.accentPressed
            : c.isHovered ? c.theme.colors.accentHover
            : resting
        let showsRule = switch underline {
        case .always: true
        case .never: false
        // Focus draws the rule too: keyboard users get no hover to reveal it.
        case .hover: c.isHovered || c.isFocused || c.isPressed
        }
        return Box(direction: .column, alignItems: .stretch, spacing: 2) {
            AnyView(c.label)
            if showsRule {
                AnyView(Box(direction: .row, alignItems: .center, spacing: 0) {}
                    .frame(height: max(1, c.theme.radius.sm * 0.25))
                    .background(ink))
            }
        }
        .foregroundColor(ink)
        .cornerRadius(c.theme.radius.sm)
        .border(c.isFocused ? c.theme.colors.focusRing : .clear, width: c.isFocused ? 2 : 0)
    }
}
