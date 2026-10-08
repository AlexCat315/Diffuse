import GuavaUICore

/// Platform fonts provide metrics and a straight-alpha RGBA bitmap without
/// coupling paragraph layout or atlas storage to a platform rasterizer.
public struct ColorGlyphSource {
    public let size: Float
    public let rasterScale: Float
    public let metrics: (UInt32) -> GlyphMetrics?
    public let lineMetrics: () -> GlyphLineMetrics
    public let rasterize: (UInt32) -> ColorGlyphBitmap?
    public init(size: Float, rasterScale: Float, metrics: @escaping (UInt32) -> GlyphMetrics?,
                lineMetrics: @escaping () -> GlyphLineMetrics, rasterize: @escaping (UInt32) -> ColorGlyphBitmap?) {
        self.size = size; self.rasterScale = rasterScale; self.metrics = metrics
        self.lineMetrics = lineMetrics; self.rasterize = rasterize
    }
}

public struct ColorGlyphBitmap {
    public let pixels: [UInt8]
    public let width: Int
    public let height: Int
    public let metrics: GlyphMetrics
    public init(pixels: [UInt8], width: Int, height: Int, metrics: GlyphMetrics) {
        self.pixels = pixels; self.width = width; self.height = height; self.metrics = metrics
    }
}
