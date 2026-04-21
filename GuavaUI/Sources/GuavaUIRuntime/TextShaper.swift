import CHarfBuzz
import CFreeType

/// Text direction for shaping.
public enum TextDirection {
    case ltr, rtl, ttb, btt

    var hbValue: hb_direction_t {
        switch self {
        case .ltr: return HB_DIRECTION_LTR
        case .rtl: return HB_DIRECTION_RTL
        case .ttb: return HB_DIRECTION_TTB
        case .btt: return HB_DIRECTION_BTT
        }
    }
}

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
}

/// Wraps HarfBuzz to perform text shaping on a FreeType font face.
///
/// Usage:
/// ```swift
/// let atlas = FontAtlas()
/// atlas.loadFont(path: "/path/to/font.ttf", size: 16)
/// let shaper = TextShaper()
/// shaper.setFont(ftFace: atlas.freetypeFace!, size: 16)
/// let glyphs = shaper.shape(text: "Hello")
/// ```
public final class TextShaper {

    private var hbFont: OpaquePointer?

    public init() {}

    deinit {
        if let font = hbFont { hb_font_destroy(font) }
    }

    /// Associates a FreeType face with this shaper.
    ///
    /// - Parameters:
    ///   - ftFace: A loaded `FT_Face`.
    ///   - size: Font size in points (used to set FreeType char size if not already set).
    public func setFont(ftFace: FT_Face, size: Float) {
        if let oldFont = hbFont {
            hb_font_destroy(oldFont)
        }
        hbFont = hb_ft_font_create_referenced(ftFace)
    }

    /// Shapes a string of text and returns positioned glyphs.
    ///
    /// - Parameters:
    ///   - text: The input string.
    ///   - direction: Text direction (default LTR).
    ///   - script: ISO 15924 script tag (default Latin). Pass nil for auto-detection.
    ///   - language: BCP 47 language tag (default "en"). Pass nil for default.
    /// - Returns: Array of shaped glyphs with positions.
    public func shape(
        text: String,
        direction: TextDirection = .ltr,
        script: hb_script_t = HB_SCRIPT_LATIN,
        language: String? = "en"
    ) -> [ShapedGlyph] {
        guard let font = hbFont else { return [] }

        let buf = hb_buffer_create()!
        defer { hb_buffer_destroy(buf) }

        text.withCString(encodedAs: UTF8.self) { ptr in
            hb_buffer_add_utf8(buf, ptr, Int32(text.utf8.count), 0, Int32(text.utf8.count))
        }

        hb_buffer_set_direction(buf, direction.hbValue)
        hb_buffer_set_script(buf, script)

        if let lang = language {
            lang.withCString { ptr in
                hb_buffer_set_language(buf, hb_language_from_string(ptr, Int32(lang.utf8.count)))
            }
        }

        hb_shape(font, buf, nil, 0)

        var glyphCount: UInt32 = 0
        guard let infos = hb_buffer_get_glyph_infos(buf, &glyphCount),
              let positions = hb_buffer_get_glyph_positions(buf, &glyphCount) else {
            return []
        }

        var result: [ShapedGlyph] = []
        result.reserveCapacity(Int(glyphCount))

        for i in 0..<Int(glyphCount) {
            let info = infos[i]
            let pos = positions[i]
            result.append(ShapedGlyph(
                glyphID: info.codepoint,
                xOffset: Float(pos.x_offset) / 64.0,
                yOffset: Float(pos.y_offset) / 64.0,
                xAdvance: Float(pos.x_advance) / 64.0,
                yAdvance: Float(pos.y_advance) / 64.0,
                cluster: info.cluster,
                fontID: 0
            ))
        }

        return result
    }
}
