import GuavaUIRuntime

// MARK: - Public API

/// Continuous, single-thumb slider bound to a `Double` value within a range.
///
/// ```swift
/// @State var volume: Double = 0.5
/// Slider(value: $volume, range: 0...1)
/// ```
///
/// Mirrors the `Button` pattern: the public struct delegates to a stateful
/// composite while the actual hit-testing and drawing live in a leaf
/// `_PrimitiveView` (`SliderHost`).
public struct Slider: View {
    public enum Axis: Sendable, Equatable { case horizontal, vertical }
    public let value: Binding<Double>
    public let range: ClosedRange<Double>
    public let step: Double?
    public let isEnabled: Bool
    public let onEditingChanged: ((Bool) -> Void)?
    /// Draws a small tick at every discrete `step` position.
    public let showsTicks: Bool
    public let axis: Axis

    public init(value: Binding<Double>,
                range: ClosedRange<Double> = 0...1,
                step: Double? = nil,
                isEnabled: Bool = true,
                onEditingChanged: ((Bool) -> Void)? = nil,
                showsTicks: Bool = false,
                axis: Axis = .horizontal) {
        self.value = value
        self.range = range
        self.step = step.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.isEnabled = isEnabled
        self.onEditingChanged = onEditingChanged
        self.showsTicks = showsTicks
        self.axis = axis
    }

    public var body: some View {
        _StatefulSlider(value: value,
                        range: range,
                        step: step,
                        isEnabled: isEnabled,
                        onEditingChanged: onEditingChanged,
                        showsTicks: showsTicks, axis: axis)
    }
}

// MARK: - Stateful wrapper

struct _StatefulSlider: View {
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let step: Double?
    let isEnabled: Bool
    let onEditingChanged: ((Bool) -> Void)?
    let showsTicks: Bool
    let axis: Slider.Axis

    var body: some View {
        SliderHost(
            value: value,
            range: range,
            step: step,
            isEnabled: isEnabled,
            onEditingChanged: onEditingChanged,
            showsTicks: showsTicks, axis: axis
        )
    }
}

