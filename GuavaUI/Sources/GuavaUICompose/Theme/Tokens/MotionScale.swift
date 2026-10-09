import Foundation

/// Cubic-Bezier easing curve described by its two control points. Phase 7.5
/// only stores these; consumption (interpolation, transitions) lands in
/// Phase 8 along with the animation system.
public struct Easing: Sendable, Equatable {
    public var c1x: Float
    public var c1y: Float
    public var c2x: Float
    public var c2y: Float

    public init(_ c1x: Float, _ c1y: Float, _ c2x: Float, _ c2y: Float) {
        self.c1x = c1x
        self.c1y = c1y
        self.c2x = c2x
        self.c2y = c2y
    }

    public static func cubicBezier(_ c1x: Float,
                                   _ c1y: Float,
                                   _ c2x: Float,
                                   _ c2y: Float) -> Easing {
        Easing(c1x, c1y, c2x, c2y)
    }

    public static let standard   = Easing(0.4, 0.0, 0.2, 1.0)
    public static let emphasized = Easing(0.2, 0.0, 0.0, 1.0)
}

/// Motion design tokens. `MotionScale` is produced in Phase 7.5 and consumed
/// by Phase 8; styles may already pass these through configuration objects so
/// later animation work needs no token rename.
public struct MotionScale: Sendable {
    public var fast: Duration
    public var standard: Duration
    public var slow: Duration
    public var emphasized: Easing
    public var standardEasing: Easing

    public init(fast: Duration,
                standard: Duration,
                slow: Duration,
                emphasized: Easing,
                standardEasing: Easing) {
        self.fast = fast
        self.standard = standard
        self.slow = slow
        self.emphasized = emphasized
        self.standardEasing = standardEasing
    }
}
