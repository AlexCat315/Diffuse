// Per-node visual description (paint *input*), kept separate from geometry and
// layout. Pure data — no GPU types — so the core stays backend-agnostic.

public struct Color: Equatable, Sendable {
    public var r: Float, g: Float, b: Float, a: Float
    public init(r: Float, g: Float, b: Float, a: Float = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }
    public static let clear = Color(r: 0, g: 0, b: 0, a: 0)
}

public struct Border: Equatable, Sendable {
    public var color: Color
    public var width: Float
    public init(color: Color, width: Float) { self.color = color; self.width = width }
}

/// What a node draws for itself. Children are drawn separately by the painter.
public struct Paint: Equatable, Sendable {
    public var background: Color?
    public var border: Border?
    public init(background: Color? = nil, border: Border? = nil) {
        self.background = background
        self.border = border
    }

    var isEmpty: Bool { background == nil && border == nil }
}
