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
        let foreground: SemanticColorRef = configuration.isSelected ? .onAccent : .onSurfaceVariant

        return BuiltinButtonChrome(kind: .toggle(minWidth: minWidth, height: height),
                                   configuration: configuration,
                                   foreground: foreground)
    }
}
