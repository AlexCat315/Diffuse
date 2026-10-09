import GuavaUIRuntime

public enum RatingPrecision: Sendable, Equatable {
    case whole, half
    public var increment: Double { self == .whole ? 1 : 0.5 }
}

/// Authored selection rules; hover/press state lives with the mounted node.
public struct RatingSelection: Sendable, Equatable {
    public var maximum = 5
    public var precision: RatingPrecision = .whole
    public var allowsClear = true
    public var isEnabled = true
    public var isReadOnly = false
    public init() {}
    mutating func validate() { maximum = max(1, min(20, maximum)) }
    var isInteractive: Bool { isEnabled && !isReadOnly }
    func clamped(_ value: Double) -> Double { value.isFinite ? max(0, min(Double(maximum), value)) : 0 }
    func snapped(_ value: Double) -> Double {
        max(allowsClear ? 0 : precision.increment, clamped((clamped(value) / precision.increment).rounded() * precision.increment))
    }
}

public struct RatingAppearance {
    public var size: ControlSize?
    public var starSize: Float?
    public var spacing: Float = 4
    public var filled: SemanticColorRef = .warning
    public var empty: SemanticColorRef = .onSurfaceMuted
    public init() {}
    mutating func validate() {
        if let starSize { self.starSize = starSize.isFinite ? max(10, min(64, starSize)) : nil }
        spacing = spacing.isFinite ? max(0, min(24, spacing)) : 4
    }
}

/// Controlled star rating with pointer preview, whole/half steps and one Tab stop.
public struct Rating: _PrimitiveView {
    public let value: Binding<Double>
    public var label = "Rating"
    public var selection = RatingSelection()
    public var appearance = RatingAppearance()
    public init(_ label: String = "Rating", value: Binding<Double>, configure: (inout Self) -> Void = { _ in }) {
        self.label = label; self.value = value
        configure(&self); selection.validate(); appearance.validate()
    }
}
