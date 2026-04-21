import CFreeType

/// Rasterizes glyphs with FreeType and packs them into an alpha-only texture atlas.
///
/// Thread safety: not thread-safe. All calls must happen on the same thread (typically the main/render thread).
public final class FontAtlas {

    private var ftLibrary: FT_Library?
    private var ftFace: FT_Face?

    /// Raw glyph atlas bitmap (single-channel alpha).
    public private(set) var atlasData: [UInt8]
    public let atlasWidth: Int
    public let atlasHeight: Int

    /// Current packing cursor (shelf packing algorithm).
    private var shelfX: Int = 0
    private var shelfY: Int = 0
    private var shelfRowHeight: Int = 0

    /// Cached glyph metrics.
    private var cache: [GlyphKey: GlyphInfo] = [:]

    /// Registered external FreeType faces for multi-font rendering.
    private var registeredFaces: [Int: RegisteredFace] = [:]

    /// Current font size in points.
    public private(set) var fontSize: Float = 0

    // MARK: - Types

    private struct GlyphKey: Hashable {
        let fontID: Int
        let glyphIndex: UInt32
        let size: Float
    }

    private struct RegisteredFace {
        let face: FT_Face
        let size: Float
    }

    /// Metrics and atlas location for a single rasterized glyph.
    public struct GlyphInfo {
        public let glyphIndex: UInt32
        public let width: Int
        public let height: Int
        public let bearingX: Int
        public let bearingY: Int
        public let advance: Float
        /// UV coordinates in the atlas (normalized 0..1).
        public let uvMinX: Float
        public let uvMinY: Float
        public let uvMaxX: Float
        public let uvMaxY: Float
    }

    // MARK: - Init / deinit

    /// Creates an atlas with the given dimensions.
    ///
    /// - Parameters:
    ///   - width: Atlas texture width in pixels (default 1024).
    ///   - height: Atlas texture height in pixels (default 1024).
    public init(width: Int = 1024, height: Int = 1024) {
        self.atlasWidth = width
        self.atlasHeight = height
        self.atlasData = [UInt8](repeating: 0, count: width * height)

        var lib: FT_Library?
        let err = FT_Init_FreeType(&lib)
        precondition(err == 0, "FT_Init_FreeType failed: \(err)")
        self.ftLibrary = lib
    }

    deinit {
        if let face = ftFace { FT_Done_Face(face) }
        if let lib = ftLibrary { FT_Done_FreeType(lib) }
    }

    // MARK: - Font loading

    /// Loads a font from a file path.
    ///
    /// - Parameters:
    ///   - path: Absolute path to a .ttf / .otf font file.
    ///   - size: Font size in points.
    public func loadFont(path: String, size: Float) {
        if let face = ftFace {
            FT_Done_Face(face)
            ftFace = nil
        }

        var face: FT_Face?
        let err = FT_New_Face(ftLibrary, path, 0, &face)
        precondition(err == 0, "FT_New_Face failed: \(err)")
        self.ftFace = face
        self.fontSize = size

        FT_Set_Char_Size(face, 0, FT_F26Dot6(size * 64), 72, 72)

        cache.removeAll()
    }

    /// The underlying FreeType face (for HarfBuzz integration).
    public var freetypeFace: FT_Face? { ftFace }

    // MARK: - Multi-font registration

    /// Registers an external FreeType face for multi-font rasterization.
    ///
    /// The caller is responsible for keeping the face alive while the atlas uses it.
    public func registerFace(_ face: FT_Face, fontID: Int, size: Float? = nil) {
        registeredFaces[fontID] = RegisteredFace(face: face, size: size ?? fontSize)
    }

    private func resolveFace(fontID: Int) -> RegisteredFace? {
        if let registered = registeredFaces[fontID] { return registered }
        if fontID == 0, let ftFace {
            return RegisteredFace(face: ftFace, size: fontSize)
        }
        return nil
    }

    // MARK: - Glyph rasterization

    /// Rasterizes a glyph by its glyph index (not codepoint) and packs it into the atlas.
    ///
    /// - Parameters:
    ///   - glyphIndex: FreeType glyph index.
    ///   - fontID: Font identifier (0 = default/stored face, others = registered faces).
    /// - Returns: Cached or newly rasterized glyph info, or nil on failure.
    public func rasterizeGlyph(glyphIndex: UInt32, fontID: Int = 0) -> GlyphInfo? {
        guard let resolved = resolveFace(fontID: fontID) else { return nil }

        let key = GlyphKey(fontID: fontID, glyphIndex: glyphIndex, size: resolved.size)
        if let cached = cache[key] { return cached }

        let face = resolved.face

        let err = FT_Load_Glyph(face, FT_UInt(glyphIndex), FT_Int32(FT_LOAD_RENDER))
        guard err == 0 else { return nil }

        guard let glyphSlot = face.pointee.glyph else { return nil }
        let bitmap = glyphSlot.pointee.bitmap
        let w = Int(bitmap.width)
        let h = Int(bitmap.rows)
        let bearingX = Int(glyphSlot.pointee.bitmap_left)
        let bearingY = Int(glyphSlot.pointee.bitmap_top)
        let advance = Float(glyphSlot.pointee.advance.x) / 64.0

        // Pack into atlas using shelf algorithm
        let (x, y) = packGlyph(width: w, height: h)
        guard x >= 0 else {
            // Atlas full
            return nil
        }

        // Copy bitmap data to atlas
        if let buffer = bitmap.buffer, w > 0, h > 0 {
            for row in 0..<h {
                let srcOffset = row * Int(bitmap.pitch)
                let dstOffset = (y + row) * atlasWidth + x
                for col in 0..<w {
                    atlasData[dstOffset + col] = buffer[srcOffset + col]
                }
            }
        }

        let info = GlyphInfo(
            glyphIndex: glyphIndex,
            width: w,
            height: h,
            bearingX: bearingX,
            bearingY: bearingY,
            advance: advance,
            uvMinX: Float(x) / Float(atlasWidth),
            uvMinY: Float(y) / Float(atlasHeight),
            uvMaxX: Float(x + w) / Float(atlasWidth),
            uvMaxY: Float(y + h) / Float(atlasHeight)
        )

        cache[key] = info
        return info
    }

    /// Rasterizes a glyph by Unicode codepoint. Convenience wrapper over `rasterizeGlyph(glyphIndex:fontID:)`.
    public func rasterizeCodepoint(_ codepoint: UInt32, fontID: Int = 0) -> GlyphInfo? {
        guard let resolved = resolveFace(fontID: fontID) else { return nil }
        let glyphIndex = FT_Get_Char_Index(resolved.face, FT_ULong(codepoint))
        guard glyphIndex != 0 else { return nil }
        return rasterizeGlyph(glyphIndex: glyphIndex, fontID: fontID)
    }

    /// Clears the atlas and cache. Keeps the loaded font.
    public func reset() {
        atlasData = [UInt8](repeating: 0, count: atlasWidth * atlasHeight)
        cache.removeAll()
        shelfX = 0
        shelfY = 0
        shelfRowHeight = 0
    }

    // MARK: - Shelf packing

    private func packGlyph(width w: Int, height h: Int) -> (x: Int, y: Int) {
        guard w > 0, h > 0 else { return (shelfX, shelfY) }

        let padding = 1

        // Does it fit on the current shelf?
        if shelfX + w + padding > atlasWidth {
            // Move to next shelf
            shelfY += shelfRowHeight + padding
            shelfX = 0
            shelfRowHeight = 0
        }

        // Does it fit vertically?
        if shelfY + h + padding > atlasHeight {
            return (-1, -1)
        }

        let x = shelfX
        let y = shelfY

        shelfX += w + padding
        if h > shelfRowHeight {
            shelfRowHeight = h
        }

        return (x, y)
    }
}
