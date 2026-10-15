import Foundation

/// Authored Bezier control points, resolved to runtime curves at the use site.
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
    public static let decelerate = Easing(0, 0, 0.2, 1)
    public static let accelerate = Easing(0.4, 0, 1, 1)
}

/// Floating surfaces share entrance, exit and reveal sizing across components.
public struct SurfaceMotion: Sendable {
    public var entrance: Duration = .milliseconds(200)
    public var exit: Duration = .milliseconds(90)
    public var revealScale: Float = 0.94
    public init() {}
}

/// Theme-owned timing and easing. Surface presentation and press feedback own
/// their defaults here; components resolve against the active node's theme.
public struct MotionScale: Sendable {
    public var fast: Duration
    public var standard: Duration
    public var slow: Duration
    public var emphasized: Easing
    public var standardEasing: Easing
    public var surface = SurfaceMotion()
    public var pressScale: Float = 0.97

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
