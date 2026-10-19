import GuavaUIRuntime

/// How finely one symbol divides: whole, half, quarter, tenth, or any 1–20
/// equal parts. Values snap to exact fractions, so `0.3` stays `0.3`.
public struct RatingPrecision: Sendable, Hashable {
    public let divisions: Int
    public static func divisions(_ count: Int) -> Self { Self(divisions: max(1, min(20, count))) }
    public static let whole = divisions(1)
    public static let half = divisions(2)
    public static let quarter = divisions(4)
    public static let tenth = divisions(10)
    public var increment: Double { 1 / Double(divisions) }
    func snapped(_ value: Double) -> Double { (value * Double(divisions)).rounded() / Double(divisions) }
    /// The value a pointer selects within one symbol: the fraction rounds up,
    /// so touching a symbol's leading edge always selects at least one part.
    func part(_ fraction: Float) -> Double {
        let parts = max(1, min(divisions, Int((Double(fraction) * Double(divisions) - 1e-4).rounded(.up))))
        return Double(parts) / Double(divisions)
    }
}

/// The glyph pair a rating paints: an empty outline under a filled glyph
/// clipped to the value. Both are tinted masks, so any monochrome icon works.
public struct RatingSymbol: Sendable, Hashable {
    public var filled: BundleImageResource
    public var empty: BundleImageResource
    public init(filled: BundleImageResource, empty: BundleImageResource) { self.filled = filled; self.empty = empty }
    public static let star = RatingSymbol(filled: UIIcons.Status.starFill, empty: UIIcons.Status.star)
    public static let heart = RatingSymbol(filled: UIIcons.Status.heartFill, empty: UIIcons.Status.heart)
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
        max(allowsClear ? 0 : precision.increment, clamped(precision.snapped(clamped(value))))
    }
}

public struct RatingAppearance {
    public var size: ControlSize?
    public var starSize: Float?
    public var symbol: RatingSymbol = .star
    public var spacing: Float = 4
    public var filled: SemanticColorRef = .warning
    public var empty: SemanticColorRef = .onSurfaceMuted
    public init() {}
    mutating func validate() {
        if let starSize { self.starSize = starSize.isFinite ? max(10, min(64, starSize)) : nil }
        spacing = spacing.isFinite ? max(0, min(24, spacing)) : 4
    }
}

/// Controlled star rating with pointer preview, whole or fractional steps, custom symbols and one Tab stop.
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
