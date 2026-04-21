import GuavaUIRuntime

/// Semantic role of a button. Styles consult this to decide whether to swap in
/// destructive coloring, etc. The role is orthogonal to the concrete style:
/// any `ButtonStyle` may opt to render `.destructive` differently from
/// `.normal`, but is not required to.
public enum ButtonRole: Sendable, Equatable {
    case normal
    case destructive
    case cancel
}

/// Snapshot of state passed to `ButtonStyle.makeBody` on every recompose.
///
/// The label is type-erased to avoid leaking the user's `Label` generic into
/// every style's body return type. `theme` is captured at body-construction
/// time so style implementations stay pure (no node lookup required).
public struct ButtonStyleConfiguration {
    public let label: any View
    public let role: ButtonRole
    public let isPressed: Bool
    public let isHovered: Bool
    public let isFocused: Bool
    public let isEnabled: Bool
    public let theme: Theme
}

/// Equatable snapshot of the interaction-driven flags of a
/// `ButtonStyleConfiguration`. Built-in styles use this as the keying value
/// for `.animation(_:value:)` so hover / press / focus / enabled transitions
/// auto-animate without the call site having to wrap state mutation in
/// `withAnimation`.
public struct _ButtonInteractionKey: Equatable, Sendable {
    public let isPressed: Bool
    public let isHovered: Bool
    public let isFocused: Bool
    public let isEnabled: Bool
}

public extension ButtonStyleConfiguration {
    /// The interaction-state subset used by built-in styles to key implicit
    /// transitions. Custom styles may use this same key, or define their own.
    var interactionKey: _ButtonInteractionKey {
        _ButtonInteractionKey(
            isPressed: isPressed,
            isHovered: isHovered,
            isFocused: isFocused,
            isEnabled: isEnabled
        )
    }
}

/// Default transition for built-in `ButtonStyle` interaction changes.
/// Tuned for snappy UI feedback — quick enough to feel direct, long enough
/// for the eye to register the colour swap.
public extension Animation {
    static let buttonInteraction = Animation(duration: 0.12, curve: .easeInOut)
}

/// SwiftUI-shaped style protocol. Implementors describe a button's complete
/// visual tree given its configuration; the `Button` primitive itself only
/// owns hit-testing and state.
public protocol ButtonStyle {
    associatedtype Body: View
    @ViewBuilder
    func makeBody(configuration: ButtonStyleConfiguration) -> Body
}

/// Type-erased `ButtonStyle` ferried through the composition tree via
/// `ButtonStyleEnvironment`. Stores the body factory as a closure.
///
/// Not actually `Sendable`-checked: built-in styles are stateless structs and
/// user styles are expected to be the same. The `@unchecked Sendable`
/// annotation lets the closure travel through `CompositionLocal<Value>` which
/// requires its `Value` to be `Sendable`.
public struct AnyButtonStyle: @unchecked Sendable {
    public let makeBody: (ButtonStyleConfiguration) -> any View

    public init<S: ButtonStyle>(_ style: S) {
        self.makeBody = { config in style.makeBody(configuration: config) }
    }
}

/// CompositionLocal that carries the active `AnyButtonStyle`. The default is
/// `PrimaryButtonStyle`, so a bare `Button(...)` always renders.
public enum ButtonStyleEnvironment {
    public static let key = CompositionLocal<AnyButtonStyle>(
        defaultValue: AnyButtonStyle(PrimaryButtonStyle())
    )
}

public extension View {
    /// Override the `ButtonStyle` used by every `Button` in this subtree.
    /// Nesting is supported; the nearest provider wins.
    func buttonStyle<S: ButtonStyle>(_ style: S) -> some View {
        compositionLocal(ButtonStyleEnvironment.key, AnyButtonStyle(style))
    }
}

// MARK: - Convenience statics

public extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}
public extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}
public extension ButtonStyle where Self == GhostButtonStyle {
    static var ghost: GhostButtonStyle { GhostButtonStyle() }
}
public extension ButtonStyle where Self == DestructiveButtonStyle {
    static var destructive: DestructiveButtonStyle { DestructiveButtonStyle() }
}
