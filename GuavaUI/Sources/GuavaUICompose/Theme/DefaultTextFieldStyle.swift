import GuavaUIRuntime

/// Recessed field chrome for dense desktop forms. The resting fill is a
/// sunken surface so inspector rows and toolbar fields read as inputs rather
/// than as generic cards.
public struct DefaultTextFieldStyle: TextFieldStyle {
    public init() {}

    public func makeBody(configuration: TextFieldStyleConfiguration) -> some View {
        let theme = configuration.theme
        let bg: Color = configuration.isEnabled
            ? theme.colors.surfaceSunken
            : theme.colors.surfaceSunken

        let border: Color = {
            if configuration.isError   { return theme.colors.error }
            if configuration.isFocused { return theme.colors.focusRing }
            return theme.colors.border
        }()
        let borderWidth: Float = configuration.isFocused ? 2 : 1

        return configuration.content
            .padding(horizontal: theme.spacing.md, vertical: theme.spacing.sm)
            .background(bg)
            .cornerRadius(theme.radius.sm)
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

