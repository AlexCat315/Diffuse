/// A single glyph produced by HarfBuzz shaping.
public struct ShapedGlyph {
    /// FreeType glyph index.
    public let glyphID: UInt32
    /// Horizontal offset from the current pen position (pixels).
    public let xOffset: Float
    /// Vertical offset from the current pen position (pixels).
    public let yOffset: Float
    /// Horizontal advance to the next glyph (pixels).
    public let xAdvance: Float
    /// Vertical advance to the next glyph (pixels).
    public let yAdvance: Float
    /// Index of the first character in the source string that maps to this glyph.
    public let cluster: UInt32
    /// Font identifier (matches FontProvider's ManagedFont.id).
    public let fontID: Int
    public init(glyphID: UInt32, xOffset: Float, yOffset: Float, xAdvance: Float, yAdvance: Float, cluster: UInt32, fontID: Int) {
        self.glyphID = glyphID
        self.xOffset = xOffset
        self.yOffset = yOffset
        self.xAdvance = xAdvance
        self.yAdvance = yAdvance
        self.cluster = cluster
        self.fontID = fontID
    }

}
