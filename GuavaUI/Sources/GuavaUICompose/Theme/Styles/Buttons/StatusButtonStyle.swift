import GuavaUIRuntime

/// Tinted semantic actions. Uses status tokens for legible text instead of assuming white ink.
public struct StatusButtonStyle: ButtonStyle, Hashable {
    public let tone: StatusTone
    public init(_ tone: StatusTone) { self.tone = tone }
    public func makeBody(configuration c: ButtonStyleConfiguration) -> some View {
        // iOS tinted-bordered action: a quiet tone wash plus a hairline in the
        // same hue. Avoid the opaque pastel block that reads as a tonal
        // Material button.
        let accent = tone.color.resolve(c.theme)
        let background = !c.isEnabled ? c.theme.colors.surfaceSunken
            : c.isPressed ? accent.multipliedAlpha(0.16).composited(over: c.theme.colors.stateLayerPressed)
            : c.isHovered ? accent.multipliedAlpha(0.10).composited(over: c.theme.colors.stateLayerHover)
            : accent.multipliedAlpha(0.06)
        let border = c.isFocused ? c.theme.colors.focusRing
            : c.isEnabled ? accent.multipliedAlpha(0.32) : c.theme.colors.border
        let verticalPadding = max(2, (c.controlSize.buttonHeight - c.theme.typography.label.lineHeight) * 0.5)
        return Row(alignment: .center) { AnyView(c.label) }
            .flex(1, shrink: 1)
            .font(.label).foregroundColor(c.isEnabled ? tone.color : .onSurfaceDisabled)
            .padding(horizontal: c.isIconOnly ? verticalPadding : c.controlSize.horizontalPadding,
                     vertical: verticalPadding)
            .frame(minWidth: c.isIconOnly ? c.controlSize.buttonHeight : 0, minHeight: c.controlSize.buttonHeight)
            .background(background).cornerRadius(c.theme.radius.md)
            .border(border, width: c.isFocused ? 2 : 1)
    }
}

public extension ButtonStyle where Self == StatusButtonStyle {
    static var success: StatusButtonStyle { StatusButtonStyle(.success) }
    static var warning: StatusButtonStyle { StatusButtonStyle(.warning) }
    static var info: StatusButtonStyle { StatusButtonStyle(.info) }
}
