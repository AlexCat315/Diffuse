import GuavaUIRuntime

enum PopoverSizing: Equatable { case content, anchor }

struct PopoverTriggerDescription {
    let label: String
    var value = ""
    var help: String?
}
/// Anchored overlay opened by a labelled trigger button.
///
/// The popup is portal-rendered, so it escapes any clipping or stacking
/// context the trigger sits in, and it is dismissed by Escape, by losing the
/// pointer, or by the trigger being pressed again.
///
/// `Popover` owns the trigger button. Surfaces that need a different trigger
/// (a hover card, a context menu) use `AnchoredOverlayHost` directly.
public struct Popover<Label: View, Content: View>: View {
    public let isPresented: Binding<Bool>
    public let isEnabled: Bool
    public let width: Float?
    public let placement: PopoverPlacement
    public let surface: PopoverSurface
    public let overflow: PopoverOverflow
    public let triggerStyle: AnyButtonStyle?
    public let label: Label
    public let content: Content
    public let onKey: ((KeyEvent, EventPhase) -> EventResult)?
    var sizing: PopoverSizing = .content
    var triggerDescription: PopoverTriggerDescription?

    public init(isPresented: Binding<Bool>,
                isEnabled: Bool = true,
                width: Float? = nil,
                placement: PopoverPlacement = .bottomLeading,
                surface: PopoverSurface = .bubble,
                overflow: PopoverOverflow = .constrain,
                triggerStyle: AnyButtonStyle? = nil,
                onKey: ((KeyEvent, EventPhase) -> EventResult)? = nil,
                @ViewBuilder label: () -> Label,
                @ViewBuilder content: () -> Content) {
        self.isPresented = isPresented
        self.isEnabled = isEnabled
        self.width = width
        self.placement = placement
        self.surface = surface
        self.overflow = overflow
        self.triggerStyle = triggerStyle
        self.onKey = onKey
        self.label = label()
        self.content = content()
    }

    public var body: some View {
        if !isEnabled && isPresented.wrappedValue { isPresented.wrappedValue = false }
        return Box(direction: .column, alignItems: sizing == .anchor ? .stretch : .flexStart, spacing: 0) {
            if let description = triggerDescription {
                trigger.compositionLocal(ActionControlAccessibility.label, description.label)
                    .compositionLocal(ActionControlAccessibility.value, description.value)
            } else {
                trigger
            }

            AnchoredOverlayHost(isPresented: isEnabled && isPresented.wrappedValue,
                                width: width,
                                placement: placement,
                                sizing: sizing,
                                surface: surface, overflow: overflow,
                                onDismiss: { isPresented.wrappedValue = false },
                                keyHandler: onKey) {
                content
            }
        }
        .zIndex(isPresented.wrappedValue ? 10_000 : 0)
    }

    @ViewBuilder private var trigger: some View {
        let button = Button(role: .normal, isEnabled: isEnabled, tooltip: triggerDescription?.help,
                            action: { isPresented.wrappedValue.toggle() }) { label }
        if let triggerStyle {
            button.buttonStyle(triggerStyle)
                .compositionLocal(ActionControlAccessibility.isExpanded, isEnabled && isPresented.wrappedValue)
        } else {
            button.buttonStyle(PopoverTriggerStyle())
                .compositionLocal(ActionControlAccessibility.isExpanded, isEnabled && isPresented.wrappedValue)
        }
    }
}

/// Trigger chrome for popovers.
///
/// A trigger owns its own look — a select pill, a colour well, an icon button,
/// a "…" menu — so this style contributes no fill, padding or hover tint. It
/// adds exactly one thing: the keyboard focus ring, drawn outside the trigger's
/// box. Pointer focus is invisible, which is why an open popover never shows a
/// ring around the control that opened it.
private struct PopoverTriggerStyle: ButtonStyle {
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        let theme = configuration.theme
        return AnyView(configuration.label)
            .cornerRadius(theme.inputs.radius)
            .border(configuration.isFocused ? theme.colors.focusRing : .clear,
                    width: configuration.isFocused ? 2 : 0)
            .animation(.semantic(.snappy, in: theme), value: configuration.interactionKey)
    }
}
