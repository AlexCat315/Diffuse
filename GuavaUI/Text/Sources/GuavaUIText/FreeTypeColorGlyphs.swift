import GuavaUICore
import CFreeType

/// FreeType-backed color glyphs for hosts without a native color rasterizer
/// (Linux, Windows). Handles COLRv0 layered outlines, which FreeType blends
/// into BGRA, and uncompressed BGRA bitmap strikes, scaled from the nearest
/// strike to the requested size. PNG-compressed strikes (CBDT/sbix) need a
/// FreeType built with PNG support and report no bitmap otherwise.
///
/// Like `FontAtlas`, an instance belongs to one render thread and must not
/// outlive the face.
public final class FreeTypeColorGlyphFace {
    private let face: FT_Face
    public let size: Float
    public let rasterScale: Float
    /// Physical-to-strike ratio; 1 for scalable faces.
    private let strikeScale: Float

    public static func hasColorGlyphs(_ face: FT_Face) -> Bool {
        face.pointee.face_flags & FT_Long(FT_FACE_FLAG_COLOR) != 0
    }

    public init?(face: FT_Face, size: Float, rasterScale: Float) {
        guard Self.hasColorGlyphs(face), size.isFinite, size > 0 else { return nil }
        self.face = face
        self.size = size
        self.rasterScale = max(1, rasterScale)
        let pixels = size * self.rasterScale
        if face.pointee.face_flags & FT_Long(FT_FACE_FLAG_SCALABLE) != 0 {
            strikeScale = 1
        } else {
            let count = Int(face.pointee.num_fixed_sizes)
            guard count > 0, let sizes = face.pointee.available_sizes else { return nil }
            // Prefer the smallest strike at or above the target, else the largest.
            let ppems = (0..<count).map { Float(sizes[$0].y_ppem) / 64 }
            let index = ppems.indices.filter { ppems[$0] >= pixels }.min { ppems[$0] < ppems[$1] }
                ?? ppems.indices.max { ppems[$0] < ppems[$1] }!
            strikeScale = ppems[index] > 0 ? pixels / ppems[index] : 1
            FT_Select_Size(face, FT_Int(index))
        }
    }

    public var source: ColorGlyphSource {
        ColorGlyphSource(size: size, rasterScale: rasterScale, metrics: { [self] in metrics($0) },
                         lineMetrics: { [self] in lineMetrics() }, rasterize: { [self] in rasterize($0) })
    }

    private func applySize() {
        if strikeScale == 1 { FT_Set_Char_Size(face, 0, FT_F26Dot6(size * rasterScale * 64), 72, 72) }
    }

    /// Logical units per FreeType pixel.
    private var unit: Float { strikeScale / rasterScale }

    public func metrics(_ index: UInt32) -> GlyphMetrics? {
        rasterize(index)?.metrics
    }

    public func lineMetrics() -> GlyphLineMetrics {
        applySize()
        guard let metrics = face.pointee.size?.pointee.metrics else {
            return GlyphLineMetrics(ascent: size * 0.8, descent: size * 0.2, lineHeight: size * 1.2)
        }
        let ascent = Float(metrics.ascender) / 64 * unit, descent = Float(-metrics.descender) / 64 * unit
        let height = Float(metrics.height) / 64 * unit
        return GlyphLineMetrics(ascent: ascent, descent: descent, lineHeight: max(height, ascent + descent))
    }

    /// Straight-alpha sRGB pixels at physical resolution, plus logical metrics.
    public func rasterize(_ index: UInt32) -> ColorGlyphBitmap? {
        applySize()
        guard FT_Load_Glyph(face, FT_UInt(index), FT_Int32(FT_LOAD_COLOR)) == 0, let slot = face.pointee.glyph else { return nil }
        if slot.pointee.format != FT_GLYPH_FORMAT_BITMAP,
           FT_Render_Glyph(slot, FT_RENDER_MODE_NORMAL) != 0 { return nil }
        let bitmap = slot.pointee.bitmap
        let sourceWidth = Int(bitmap.width), sourceHeight = Int(bitmap.rows)
        let advance = Float(slot.pointee.advance.x) / 64 * unit
        guard sourceWidth > 0, sourceHeight > 0, let buffer = bitmap.buffer else {
            return ColorGlyphBitmap(pixels: [], width: 0, height: 0, metrics: GlyphMetrics(
                glyphIndex: index, width: 0, height: 0, bearingX: 0, bearingY: 0, advance: advance))
        }
        let pitch = Int(bitmap.pitch)
        var source = [UInt8](repeating: 0, count: sourceWidth * sourceHeight * 4)
        for y in 0..<sourceHeight {
            let row = buffer + (pitch >= 0 ? y * pitch : (sourceHeight - 1 - y) * -pitch)
            for x in 0..<sourceWidth {
                let out = (y * sourceWidth + x) * 4
                switch bitmap.pixel_mode {
                case UInt8(FT_PIXEL_MODE_BGRA.rawValue):
                    // Premultiplied BGRA → straight RGBA.
                    let b = Int(row[x * 4]), g = Int(row[x * 4 + 1]), r = Int(row[x * 4 + 2]), a = Int(row[x * 4 + 3])
                    func unpremultiply(_ c: Int) -> UInt8 { a == 0 ? 0 : UInt8(min(255, (c * 255 + a / 2) / a)) }
                    source[out] = unpremultiply(r); source[out + 1] = unpremultiply(g)
                    source[out + 2] = unpremultiply(b); source[out + 3] = UInt8(a)
                case UInt8(FT_PIXEL_MODE_GRAY.rawValue):
                    // A monochrome glyph inside a color face draws as black ink.
                    source[out + 3] = row[x]
                default:
                    return nil
                }
            }
        }
        let width = max(1, Int((Float(sourceWidth) * strikeScale).rounded()))
        let height = max(1, Int((Float(sourceHeight) * strikeScale).rounded()))
        let pixels = strikeScale == 1 ? source
            : Self.resample(source, width: sourceWidth, height: sourceHeight, toWidth: width, toHeight: height)
        let metrics = GlyphMetrics(glyphIndex: index,
                                   width: Float(width) / rasterScale, height: Float(height) / rasterScale,
                                   bearingX: Float(slot.pointee.bitmap_left) * unit,
                                   bearingY: Float(slot.pointee.bitmap_top) * unit,
                                   advance: advance)
        return ColorGlyphBitmap(pixels: pixels, width: width, height: height, metrics: metrics)
    }

    /// Box-filtered resample of straight-alpha RGBA, weighting color by alpha
    /// so transparent edges do not darken.
    static func resample(_ pixels: [UInt8], width: Int, height: Int, toWidth: Int, toHeight: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: toWidth * toHeight * 4)
        let sx = Float(width) / Float(toWidth), sy = Float(height) / Float(toHeight)
        for y in 0..<toHeight {
            let y0 = Int(Float(y) * sy), y1 = max(y0 + 1, min(height, Int((Float(y + 1) * sy).rounded(.up))))
            for x in 0..<toWidth {
                let x0 = Int(Float(x) * sx), x1 = max(x0 + 1, min(width, Int((Float(x + 1) * sx).rounded(.up))))
                var r = 0, g = 0, b = 0, a = 0, count = 0
                for v in y0..<min(y1, height) {
                    for u in x0..<min(x1, width) {
                        let i = (v * width + u) * 4, alpha = Int(pixels[i + 3])
                        r += Int(pixels[i]) * alpha; g += Int(pixels[i + 1]) * alpha; b += Int(pixels[i + 2]) * alpha
                        a += alpha; count += 1
                    }
                }
                let o = (y * toWidth + x) * 4
                guard count > 0 else { continue }
                if a > 0 { result[o] = UInt8(r / a); result[o + 1] = UInt8(g / a); result[o + 2] = UInt8(b / a) }
                result[o + 3] = UInt8(a / count)
            }
        }
        return result
    }
}
