import GuavaUIRuntime

/// Filled surface with a 1px border that thickens to the focus ring colour
/// when focused. Error state swaps the border for the error slot.
public struct DefaultTextFieldStyle: TextFieldStyle {
    public init() {}

    public func makeBody(configuration: TextFieldStyleConfiguration) -> some View {
        let theme = configuration.theme
        let bg: Color = configuration.isEnabled
            ? theme.colors.surfaceVariant
            : theme.colors.surfaceSunken

        let border: Color = {
            if configuration.isError   { return theme.colors.error }
            if configuration.isFocused { return theme.colors.focusRing }
            return theme.colors.borderStrong
        }()
        let borderWidth: Float = configuration.isFocused ? 2 : 1

        return configuration.content
            .padding(horizontal: theme.spacing.md, vertical: theme.spacing.sm + 2)
            .background(bg)
            .cornerRadius(theme.radius.md)
            .border(border, width: borderWidth)
            .opacity(configuration.isEnabled ? 1 : 0.55)
            .animation(.fast, value: _TextFieldInteractionKey(
                isFocused: configuration.isFocused,
                isError:   configuration.isError,
                isEnabled: configuration.isEnabled
            ))
    }
}

public struct _TextFieldInteractionKey: Equatable, Sendable {
    public let isFocused: Bool
    public let isError: Bool
    public let isEnabled: Bool
}

public extension Animation {
    /// 80ms ease-out — quick enough to feel direct on focus changes.
    static let fast = Animation(duration: 0.08, curve: .easeOut)
}

