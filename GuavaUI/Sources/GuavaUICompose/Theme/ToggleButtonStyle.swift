import GuavaUIRuntime

/// On/off chip for toolbars, segmented choices, and view-mode switches.
/// Reads `configuration.isSelected` (set via `Button(isSelected:)`): solid
/// accent with `onAccent` foreground when on — the theme guarantees that
/// pairing's contrast — transparent with state-layer washes when off.
///
/// ```swift
/// Button(isSelected: mode == .grid, action: { mode = .grid }) { Text("Grid") }
///     .buttonStyle(.toggle)
/// ```
public struct ToggleButtonStyle: ButtonStyle, Hashable {
    public var minWidth: Float
    public var height: Float

    public init(minWidth: Float = 28, height: Float = 26) {
        self.minWidth = minWidth
        self.height = height
    }

    public func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        let theme = configuration.theme
        let clear = Color(r: 0, g: 0, b: 0, a: 0)
        let bg: Color = {
            if !configuration.isEnabled { return clear }
            if configuration.isSelected {
                if configuration.isPressed { return theme.colors.accentPressed }
                if configuration.isHovered { return theme.colors.accentHover }
                return theme.colors.accent
            }
            if configuration.isPressed { return theme.colors.stateLayerPressed }
            if configuration.isHovered { return theme.colors.stateLayerHover }
            return clear
        }()
        let border: Color = configuration.isFocused ? theme.colors.focusRing : clear
        let borderWidth: Float = configuration.isFocused ? 2 : 0
        let foreground: SemanticColorRef = configuration.isSelected ? .onAccent : .onSurfaceVariant

        return Box(direction: .row, alignItems: .center, justifyContent: .center) {
            AnyView(configuration.label)
                .font(SemanticFontRef.label)
                .foregroundColor(foreground)
        }
        .frame(height: height, minWidth: minWidth)
        .padding(horizontal: 7, vertical: 0)
        .background(bg)
        .cornerRadius(6)
        .border(border, width: borderWidth)
        .opacity(configuration.isEnabled ? 1 : 0.55)
        .animation(.semantic(.snappy, in: theme), value: configuration.interactionKey)
    }
}
