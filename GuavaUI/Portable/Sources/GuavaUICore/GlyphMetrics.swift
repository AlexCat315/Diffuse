public struct GlyphAtlasInfo {
    public let glyphIndex: UInt32
    public let width: Float
    public let height: Float
    public let bearingX: Float
    public let bearingY: Float
    public let advance: Float
    public let uvMinX: Float
    public let uvMinY: Float
    public let uvMaxX: Float
    public let uvMaxY: Float

    public init(glyphIndex: UInt32, width: Float, height: Float, bearingX: Float, bearingY: Float, advance: Float, uvMinX: Float, uvMinY: Float, uvMaxX: Float, uvMaxY: Float) {
        self.glyphIndex = glyphIndex
        self.width = width
        self.height = height
        self.bearingX = bearingX
        self.bearingY = bearingY
        self.advance = advance
        self.uvMinX = uvMinX
        self.uvMinY = uvMinY
        self.uvMaxX = uvMaxX
        self.uvMaxY = uvMaxY
    }
}

public struct GlyphMetrics {
    public let glyphIndex: UInt32
    public let width: Float
    public let height: Float
    public let bearingX: Float
    public let bearingY: Float
    public let advance: Float

    public init(glyphIndex: UInt32, width: Float, height: Float, bearingX: Float, bearingY: Float, advance: Float) {
        self.glyphIndex = glyphIndex
        self.width = width
        self.height = height
        self.bearingX = bearingX
        self.bearingY = bearingY
        self.advance = advance
    }
}

public struct GlyphLineMetrics {
    public let ascent: Float
    public let descent: Float
    public let lineHeight: Float

    public init(ascent: Float, descent: Float, lineHeight: Float) {
        self.ascent = ascent
        self.descent = descent
        self.lineHeight = lineHeight
    }
}

public protocol GlyphMetricsProvider: AnyObject {
    func glyphMetrics(glyphIndex: UInt32, fontID: Int) -> GlyphMetrics?
    func lineMetrics(fontID: Int) -> GlyphLineMetrics?
}
