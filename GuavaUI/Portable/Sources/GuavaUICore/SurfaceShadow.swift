import Foundation

/// One layer of a surface's drop shadow.
///
/// A single layer can only do one job: spread a broad, faint halo, or draw a
/// tight dark contact line under the surface. Floating panels need both, which
/// is why `LayeredShadow` pairs them.
public struct SurfaceShadow: Sendable, Equatable {
    /// `nil` or zero alpha skips the layer.
    public var color: Color?
    public var offsetX: Float
    public var offsetY: Float
    /// Logical blur radius. Renderers without a real blur approximate it with
    /// a stack of expanded translucent rects.
    public var blur: Float

    public init(color: Color? = nil, offsetX: Float = 0, offsetY: Float = 0, blur: Float = 0) {
        self.color = color
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.blur = blur
    }

    public static let none = SurfaceShadow()

    /// Whether painting this layer would emit anything.
    public var isEmpty: Bool {
        guard let color else { return true }
        return color.a <= 0
    }
}

/// A raised surface's shadow: an ambient halo beneath a tighter key shadow.
///
/// The ambient layer is wide and faint — it separates the whole panel from what
/// is under it. The key layer is narrow and darker, offset further down, and it
/// is what makes the panel look close to the surface rather than miles away.
public struct LayeredShadow: Sendable, Equatable {
    public var ambient: SurfaceShadow
    public var key: SurfaceShadow

    public init(ambient: SurfaceShadow, key: SurfaceShadow) {
        self.ambient = ambient
        self.key = key
    }

    /// A single shadow, as every surface had before floating panels gained a
    /// second layer: no ambient halo.
    public init(_ key: SurfaceShadow) {
        self.ambient = .none
        self.key = key
    }

    public static let none = LayeredShadow(ambient: .none, key: .none)
}
