import GuavaUICore
import CFreeType
import CHarfBuzz

/// An ordered set of owned font faces sharing one alpha atlas. This performs
/// grapheme-safe fallback and script-run shaping; paragraph bidi is a host concern.
/// Like FreeType and DrawList, instances belong to one render thread.
public final class FontCollection {
    public let atlas: FontAtlas
    private var faces: [FontAtlas] = []
    public var fontCount: Int { faces.count }
    public private(set) var size: Float = 16
    public private(set) var rasterScale: Float = 1

    public init(width: Int = 2048, height: Int = 2048) {
        atlas = FontAtlas(width: width, height: height)
        atlas.reset()
    }

    /// IDs are stable, one-based, and returned only after successful loading.
    @discardableResult public func append(bytes: [UInt8]) -> Int? {
        let owner = FontAtlas(width: 1, height: 1)
        guard owner.loadFont(bytes: bytes, size: size, rasterScale: rasterScale),
              let face = owner.freetypeFace else { return nil }
        faces.append(owner)
        atlas.registerFace(face, fontID: faces.count, size: size, rasterScale: rasterScale)
        return faces.count
    }

    /// Reuses atlas entries across sizes. FreeType's active size and atlas cache
    /// keys must change together, even when a previous shape is reused by a host.
    public func configure(size: Float, rasterScale: Float = 1) {
        guard size.isFinite, size > 0, size <= 512,
              rasterScale.isFinite, (1...4).contains(rasterScale) else { return }
        self.size = size; self.rasterScale = rasterScale
        for (index, owner) in faces.enumerated() {
            guard let face = owner.freetypeFace else { continue }
            FT_Set_Char_Size(face, 0, FT_F26Dot6(size * rasterScale * 64), 72, 72)
            atlas.registerFace(face, fontID: index + 1, size: size, rasterScale: rasterScale)
        }
    }

    public func shape(_ text: String) -> [ShapedGlyph] {
        guard !faces.isEmpty else { return [] }
        struct Run { var text: String; var font: Int; var script: hb_script_t; var offset: UInt32 }
        var runs: [Run] = []
        var offset: UInt32 = 0
        let unicode = hb_unicode_funcs_get_default()
        for character in text {
            let string = String(character)
            let scalars = string.unicodeScalars.filter {
                // Format controls influence shaping but have no standalone glyph.
                $0.properties.generalCategory != .format &&
                !(0xFE00...0xFE0F).contains($0.value) && !(0xE0100...0xE01EF).contains($0.value)
            }
            let strongScript = scalars.lazy.map { hb_unicode_script(unicode, $0.value) }.first {
                $0 != HB_SCRIPT_COMMON && $0 != HB_SCRIPT_INHERITED && $0 != HB_SCRIPT_UNKNOWN
            }
            let script = strongScript ?? runs.last?.script ?? HB_SCRIPT_COMMON
            func covers(_ index: Int) -> Bool {
                let face = faces[index].freetypeFace!
                return scalars.allSatisfy { FT_Get_Char_Index(face, FT_ULong($0.value)) != 0 }
            }
            // Common punctuation/spacing stays in the current face when possible.
            let previous = runs.last?.font
            let font = strongScript == nil && previous.map(covers) == true
                ? previous! : faces.indices.first(where: covers) ?? 0
            if let last = runs.last, last.font == font, last.script == script {
                runs[runs.count - 1].text += string
            } else { runs.append(Run(text: string, font: font, script: script, offset: offset)) }
            offset += UInt32(string.utf8.count)
        }
        return runs.flatMap { run in
            let shaper = TextShaper()
            shaper.setFont(ftFace: faces[run.font].freetypeFace!, size: size, rasterScale: rasterScale)
            return shaper.shape(text: run.text, direction: nil, script: run.script, language: nil).map {
                ShapedGlyph(glyphID: $0.glyphID, xOffset: $0.xOffset, yOffset: $0.yOffset,
                            xAdvance: $0.xAdvance, yAdvance: $0.yAdvance,
                            cluster: $0.cluster + run.offset, fontID: run.font + 1)
            }
        }
    }

    /// Appends actual atlas quads to the same DrawList used for UI geometry.
    /// Returns the layout width, suitable for an IME candidate-window position.
    @discardableResult public func draw(_ text: String, size: Float, rasterScale: Float = 1,
                                       into list: DrawList, x: Float, y: Float,
                                       color: Color, textureID: TextureID = 1) -> Float {
        guard size.isFinite, size > 0, size <= 512,
              rasterScale.isFinite, (1...4).contains(rasterScale), x.isFinite, y.isFinite else { return 0 }
        configure(size: size, rasterScale: rasterScale)
        let shaped = shape(text)
        let layout = TextLayout.layout(shapedGlyphs: shaped, text: text, atlas: atlas, lineHeight: size * 1.4)
        for line in layout.lines {
            for glyph in line.glyphs {
                guard let info = atlas.rasterizeGlyph(glyphIndex: glyph.glyphID, fontID: glyph.fontID),
                      info.width > 0, info.height > 0 else { continue }
                func snap(_ value: Float) -> Float { (value * self.rasterScale).rounded() / self.rasterScale }
                list.addGlyphQuad(x: snap(x + glyph.x + info.bearingX), y: snap(y + glyph.y - info.bearingY),
                                  width: info.width, height: info.height,
                                  uvMinX: info.uvMinX, uvMinY: info.uvMinY, uvMaxX: info.uvMaxX, uvMaxY: info.uvMaxY,
                                  color: color, textureID: textureID)
            }
        }
        return layout.totalWidth
    }
}
