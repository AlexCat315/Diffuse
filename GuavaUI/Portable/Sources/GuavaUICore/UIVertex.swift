/// Vertex format used by the UI render pipeline.
///
/// Layout (20 bytes, packed):
///   - `pos`   : `float32x2` at offset 0  (screen-space pixels, top-left origin)
///   - `uv`    : `float32x2` at offset 8  (atlas UV in 0..1; sentinel `(-1, mode)` for non-textured shapes)
///   - `color` : `unorm8x4`  at offset 16 (premultiplied RGBA)
public struct UIVertex: Sendable {
    public var posX: Float
    public var posY: Float
    public var u: Float
    public var v: Float
    public var color: UInt32

    public init(posX: Float, posY: Float, u: Float, v: Float, color: UInt32) {
        self.posX = posX
        self.posY = posY
        self.u = u
        self.v = v
        self.color = color
    }

    /// Stride in bytes. Must match the WGSL vertex layout.
    public static let stride: Int = 20
}

/// Axis-aligned rectangle in screen-space pixels (top-left origin).
public struct UIRect: Equatable, Sendable {
    public var x: Float
    public var y: Float
    public var width: Float
    public var height: Float

    public init(x: Float, y: Float, width: Float, height: Float) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public var minX: Float { x }
    public var minY: Float { y }
    public var maxX: Float { x + width }
    public var maxY: Float { y + height }
}
