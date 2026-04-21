import Foundation
import CoreGraphics

/// Linearly-blendable values. `t` is clamped to `[0, 1]` by callers; the
/// scheduler always passes pre-clamped progress, so implementations may
/// assume the bound holds.
///
/// Conformances live next to the type they describe: `Color`, `CGRect`, and
/// the numeric primitives ship with `GuavaUIRuntime`; Compose-layer types
/// such as `EdgeInsets` add their conformance in `GuavaUICompose`.
public protocol Interpolatable {
    static func interpolate(_ a: Self, _ b: Self, t: Float) -> Self
}

// MARK: - Numeric primitives

extension Float: Interpolatable {
    public static func interpolate(_ a: Float, _ b: Float, t: Float) -> Float {
        a + (b - a) * t
    }
}

extension Double: Interpolatable {
    public static func interpolate(_ a: Double, _ b: Double, t: Float) -> Double {
        a + (b - a) * Double(t)
    }
}

extension CGFloat: Interpolatable {
    public static func interpolate(_ a: CGFloat, _ b: CGFloat, t: Float) -> CGFloat {
        a + (b - a) * CGFloat(t)
    }
}

// MARK: - Color

extension Color: Interpolatable {
    /// Component-wise linear blend in straight-alpha RGBA. Premultiplied
    /// blending is intentionally not used here — the renderer expects
    /// straight-alpha colors and Phase 8's animation surface is per-property.
    public static func interpolate(_ a: Color, _ b: Color, t: Float) -> Color {
        Color(
            r: Float.interpolate(a.r, b.r, t: t),
            g: Float.interpolate(a.g, b.g, t: t),
            b: Float.interpolate(a.b, b.b, t: t),
            a: Float.interpolate(a.a, b.a, t: t)
        )
    }
}

// MARK: - Geometry

extension CGRect: Interpolatable {
    public static func interpolate(_ a: CGRect, _ b: CGRect, t: Float) -> CGRect {
        CGRect(
            x: CGFloat.interpolate(a.origin.x, b.origin.x, t: t),
            y: CGFloat.interpolate(a.origin.y, b.origin.y, t: t),
            width: CGFloat.interpolate(a.size.width, b.size.width, t: t),
            height: CGFloat.interpolate(a.size.height, b.size.height, t: t)
        )
    }
}

extension CGPoint: Interpolatable {
    public static func interpolate(_ a: CGPoint, _ b: CGPoint, t: Float) -> CGPoint {
        CGPoint(
            x: CGFloat.interpolate(a.x, b.x, t: t),
            y: CGFloat.interpolate(a.y, b.y, t: t)
        )
    }
}

extension CGSize: Interpolatable {
    public static func interpolate(_ a: CGSize, _ b: CGSize, t: Float) -> CGSize {
        CGSize(
            width: CGFloat.interpolate(a.width, b.width, t: t),
            height: CGFloat.interpolate(a.height, b.height, t: t)
        )
    }
}
