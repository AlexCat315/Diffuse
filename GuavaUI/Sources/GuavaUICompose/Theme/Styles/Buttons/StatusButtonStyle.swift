import GuavaUIRuntime

/// Tinted semantic actions. Uses status tokens for legible text instead of assuming white ink.
public struct StatusButtonStyle: ButtonStyle, Hashable {
    public let tone: StatusTone
    public init(_ tone: StatusTone) { self.tone = tone }
    public func makeBody(configuration c: ButtonStyleConfiguration) -> some View {
        let fill = tone.color.resolve(c.theme).multipliedAlpha(0.12)
        let background = !c.isEnabled ? c.theme.colors.surfaceSunken
            : c.isPressed ? fill.composited(over: c.theme.colors.stateLayerPressed)
            : c.isHovered ? fill.composited(over: c.theme.colors.stateLayerHover) : fill
        return Row(alignment: .center) { AnyView(c.label) }
            .flex(1, shrink: 1)
            .font(.label).foregroundColor(c.isEnabled ? tone.color : .onSurfaceDisabled)
            .padding(horizontal: c.controlSize.horizontalPadding)
            .frame(height: c.controlSize.buttonHeight).background(background).cornerRadius(c.theme.radius.md)
            .border(c.isFocused ? c.theme.colors.focusRing : .clear, width: c.isFocused ? 2 : 0)
    }
}

public extension ButtonStyle where Self == StatusButtonStyle {
    static var success: StatusButtonStyle { StatusButtonStyle(.success) }
    static var warning: StatusButtonStyle { StatusButtonStyle(.warning) }
    static var info: StatusButtonStyle { StatusButtonStyle(.info) }
}
