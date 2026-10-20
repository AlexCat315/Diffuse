import Foundation

/// A two-stop linear gradient across a shape's bounds.
///
/// `angle` is in degrees, measured like CSS: 0 runs bottom to top, 90 left to
/// right, 135 from the top-left corner to the bottom-right corner. The start
/// color sits on the edge the direction leaves from; the end color on the
/// opposite edge, so the full ramp always spans the shape.
public struct UILinearGradient: Equatable, Sendable {
    public var start: Color
    public var end: Color
    public var angle: Float

    public init(_ start: Color, _ end: Color, angle: Float = 180) {
        self.start = start
        self.end = end
        self.angle = angle
    }

    /// The color at a point inside `rect`.
    public func color(atX x: Float, y: Float, in rect: UIRect) -> Color {
        let radians = angle * .pi / 180
        // Screen y grows downward, so CSS 0° (upwards) is (0, -1).
        let dx = Float(sin(Double(radians))), dy = Float(-cos(Double(radians)))
        let halfSpan = (abs(rect.width * dx) + abs(rect.height * dy)) / 2
        guard halfSpan > 0 else { return start }
        let cx = rect.minX + rect.width / 2, cy = rect.minY + rect.height / 2
        let t = max(0, min(1, ((x - cx) * dx + (y - cy) * dy) / (2 * halfSpan) + 0.5))
        return Color(r: start.r + (end.r - start.r) * t,
                     g: start.g + (end.g - start.g) * t,
                     b: start.b + (end.b - start.b) * t,
                     a: start.a + (end.a - start.a) * t)
    }

    public func multipliedAlpha(_ factor: Float) -> UILinearGradient {
        UILinearGradient(start.multipliedAlpha(factor), end.multipliedAlpha(factor), angle: angle)
    }
}

public extension DrawList {
    /// A rounded fill whose color follows `gradient`. It reuses the solid
    /// rounded geometry, including its one-pixel coverage fringe, and colors
    /// each vertex by position; a two-stop linear ramp interpolates exactly
    /// across triangles.
    func addLinearGradient(_ rect: UIRect, radius: Float, gradient: UILinearGradient) {
        guard rect.width > 0, rect.height > 0 else { return }
        let first = vertices.count
        addRoundedRect(rect, radius: radius, color: Color(r: 1, g: 1, b: 1, a: 1))
        recolor(from: first) { x, y, coverage in
            gradient.color(atX: x, y: y, in: rect).multipliedAlpha(coverage)
        }
    }
}
