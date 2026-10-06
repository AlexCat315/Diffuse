/// Linear RGBA color in 0..1 float range.
///
/// Stored as floats for ease of composition; packed to 8-bit per channel via
/// `rgba8` when uploaded to the GPU vertex stream.
public struct Color: Equatable, Sendable {
    public var r: Float
    public var g: Float
    public var b: Float
    public var a: Float

    public init(r: Float, g: Float, b: Float, a: Float = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    /// Convenience initializer from 8-bit components.
    public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
        self.r = Float(red) / 255.0
        self.g = Float(green) / 255.0
        self.b = Float(blue) / 255.0
        self.a = Float(alpha) / 255.0
    }

    /// Packed little-endian RGBA with 8 bits per channel (R in low byte, A in high byte).
    /// Matches WGSL `vec4<f32>(unpack4x8unorm(c))` decoding.
    public var rgba8: UInt32 {
        let rb = UInt32(max(0, min(255, Int((r * 255).rounded()))))
        let gb = UInt32(max(0, min(255, Int((g * 255).rounded()))))
        let bb = UInt32(max(0, min(255, Int((b * 255).rounded()))))
        let ab = UInt32(max(0, min(255, Int((a * 255).rounded()))))
        return rb | (gb << 8) | (bb << 16) | (ab << 24)
    }

    public func multipliedAlpha(_ opacity: Float) -> Color {
        let clamped = max(0, min(1, opacity))
        guard clamped < 1 else { return self }
        return Color(r: r, g: g, b: b, a: a * clamped)
    }

    /// Source-over compositing with `overlay` painted on top of `self`.
    /// Both colours are treated as straight-alpha RGBA. Used by state-layer
    /// overlays so a translucent hover/press tint produces a real surface
    /// colour (not a separate token per state).
    public func composited(over overlay: Color) -> Color {
        let oa = max(0, min(1, overlay.a))
        let outA = oa + a * (1 - oa)
        guard outA > 0 else { return Color(r: 0, g: 0, b: 0, a: 0) }
        let outR = (overlay.r * oa + r * a * (1 - oa)) / outA
        let outG = (overlay.g * oa + g * a * (1 - oa)) / outA
        let outB = (overlay.b * oa + b * a * (1 - oa)) / outA
        return Color(r: outR, g: outG, b: outB, a: outA)
    }

    public static let clear = Color(r: 0, g: 0, b: 0, a: 0)
    public static let black = Color(r: 0, g: 0, b: 0)
    public static let white = Color(r: 1, g: 1, b: 1)
}
