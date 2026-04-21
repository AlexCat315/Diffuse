import GuavaUIRuntime

// MARK: - Configuration

/// Snapshot of state passed to `SliderStyle.resolve` on every recompose.
public struct SliderStyleConfiguration {
    public let value: Double
    public let range: ClosedRange<Double>
    public let isPressed: Bool
    public let isHovered: Bool
    public let isFocused: Bool
    public let isEnabled: Bool
    public let theme: Theme

    public var fraction: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(1, max(0, (value - range.lowerBound) / span))
    }
}

/// Equatable subset of the interaction flags used by built-in styles to key
/// implicit transitions, mirroring `_ButtonInteractionKey`.
public struct _SliderInteractionKey: Equatable, Sendable {
    public let isPressed: Bool
    public let isHovered: Bool
    public let isFocused: Bool
    public let isEnabled: Bool
}

public extension SliderStyleConfiguration {
    var interactionKey: _SliderInteractionKey {
        _SliderInteractionKey(
            isPressed: isPressed,
            isHovered: isHovered,
            isFocused: isFocused,
            isEnabled: isEnabled
        )
    }
}

/// Default transition for built-in `SliderStyle` interaction changes.
public extension Animation {
    static let sliderInteraction = Animation(duration: 0.12, curve: .easeInOut)
}

// MARK: - Appearance

/// Pure-data description of how a slider should be drawn for one frame.
///
/// `SliderStyle` returns this instead of a `View` because the filled-track and
/// thumb positions depend on the host's measured width, which is only known at
/// draw time. The host primitive consumes the appearance and emits the actual
/// quads.
public struct SliderAppearance: Equatable, Sendable {
    public var trackHeight: Float
    public var trackColor: Color
    public var fillColor: Color
    public var thumbDiameter: Float
    public var thumbColor: Color
    public var thumbBorderColor: Color?
    public var thumbBorderWidth: Float
    public var trackCornerRadius: Float

    public init(trackHeight: Float,
                trackColor: Color,
                fillColor: Color,
                thumbDiameter: Float,
                thumbColor: Color,
                thumbBorderColor: Color? = nil,
                thumbBorderWidth: Float = 0,
                trackCornerRadius: Float) {
        self.trackHeight = trackHeight
        self.trackColor = trackColor
        self.fillColor = fillColor
        self.thumbDiameter = thumbDiameter
        self.thumbColor = thumbColor
        self.thumbBorderColor = thumbBorderColor
        self.thumbBorderWidth = thumbBorderWidth
        self.trackCornerRadius = trackCornerRadius
    }
}

// MARK: - Protocol

public protocol SliderStyle {
    func resolve(configuration: SliderStyleConfiguration) -> SliderAppearance
}

/// Type-erased `SliderStyle` ferried through the composition tree via
/// `SliderStyleEnvironment`.
public struct AnySliderStyle: @unchecked Sendable {
    public let resolve: (SliderStyleConfiguration) -> SliderAppearance

    public init<S: SliderStyle>(_ style: S) {
        self.resolve = { config in style.resolve(configuration: config) }
    }
}

public enum SliderStyleEnvironment {
    public static let key = CompositionLocal<AnySliderStyle>(
        defaultValue: AnySliderStyle(DefaultSliderStyle())
    )
}

public extension View {
    /// Override the `SliderStyle` used by every `Slider` in this subtree.
    func sliderStyle<S: SliderStyle>(_ style: S) -> some View {
        compositionLocal(SliderStyleEnvironment.key, AnySliderStyle(style))
    }
}

public extension SliderStyle where Self == DefaultSliderStyle {
    static var `default`: DefaultSliderStyle { DefaultSliderStyle() }
}

// MARK: - DefaultSliderStyle

/// Built-in style. Horizontal track with a filled accent segment and a circular
/// thumb. Hover / press tweak the thumb fill via `Color.lighter` / `darker`.
public struct DefaultSliderStyle: SliderStyle {
    public init() {}

    public func resolve(configuration c: SliderStyleConfiguration) -> SliderAppearance {
        let theme = c.theme
        let track = theme.colors.surfaceVariant
        let fill: Color = c.isEnabled ? theme.colors.accent
                                      : theme.colors.surfaceVariant
        let thumbBase: Color = c.isEnabled ? theme.colors.accent
                                           : theme.colors.surfaceVariant
        let thumb: Color = {
            if !c.isEnabled { return thumbBase }
            if c.isPressed  { return thumbBase.darker(0.10) }
            if c.isHovered  { return thumbBase.lighter(0.06) }
            return thumbBase
        }()
        return SliderAppearance(
            trackHeight: 4,
            trackColor: track,
            fillColor: fill,
            thumbDiameter: 18,
            thumbColor: thumb,
            thumbBorderColor: c.isFocused ? theme.colors.focusRing : nil,
            thumbBorderWidth: c.isFocused ? 2 : 0,
            trackCornerRadius: theme.radius.sm
        )
    }
}
