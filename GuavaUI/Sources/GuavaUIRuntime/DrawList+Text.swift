import Foundation

// Font shaping and atlas lookup remain in the desktop runtime.
extension DrawList {
    /// Append a fully laid-out text result. The atlas texture must be registered
    /// with the renderer under `textureID`.
    public func addText(
        _ layout: TextLayoutResult,
        origin: (x: Float, y: Float),
        color: Color,
        textureID: TextureID,
        atlas: FontAtlas? = nil,
        colorForGlyph: ((PositionedGlyph) -> Color?)? = nil
    ) {
        for line in layout.lines {
            for glyph in line.glyphs {
                let info = glyph.atlasInfo ?? atlas?.rasterizeGlyph(
                    glyphIndex: glyph.glyphID,
                    fontID: glyph.fontID
                )
                guard let info, info.width > 0, info.height > 0 else { continue }
                let dx = snappedTextPixel(origin.x + glyph.x + info.bearingX)
                let dy = snappedTextPixel(origin.y + glyph.y - info.bearingY)
                addGlyphQuad(
                    x: dx, y: dy,
                    width: info.width, height: info.height,
                    uvMinX: info.uvMinX, uvMinY: info.uvMinY,
                    uvMaxX: info.uvMaxX, uvMaxY: info.uvMaxY,
                    color: colorForGlyph?(glyph) ?? color, textureID: textureID
                )
            }
        }
    }

    private func snappedTextPixel(_ value: Float) -> Float {
        // Snap to a whole *physical* pixel. The draw list is in logical
        // coordinates that the renderer scales by `ContentScaleHolder.current`
        // to physical pixels; rounding in logical space lands glyphs on
        // half-physical-pixels at fractional scales (e.g. 10→15 but 11→16.5 at
        // 1.5×), so bilinear atlas sampling smears them. The glyph quad size is
        // already an exact physical-pixel count, so a physical-aligned origin
        // makes the atlas map 1:1 to the screen and stay crisp on HiDPI.
        let scale = ContentScaleHolder.current
        guard scale.isFinite, scale > 0 else { return value.rounded() }
        return (value * scale).rounded() / scale
    }

}
