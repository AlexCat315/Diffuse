import GuavaUICore
import CFreeType

/// Packs FreeType alpha glyphs and registered color glyphs into separate atlas planes.
///
/// Thread safety: not thread-safe. All calls must happen on the same thread (typically the main/render thread).
public final class FontAtlas {

    private var ftLibrary: FT_Library?
    private var ftFace: FT_Face?

    /// Raw glyph atlas bitmap (single-channel alpha).
    public private(set) var atlasData: [UInt8]
    public let atlasWidth: Int
    public let atlasHeight: Int
    private var alphaIsDirty = false
    public var isDirty: Bool { alphaIsDirty || colorAtlas?.isDirty == true }
    private var alphaIsFull = false
    public var isFull: Bool { alphaIsFull || colorAtlas?.isFull == true }

    /// Current packing cursor (shelf packing algorithm).
    private var shelfX: Int = 0
    private var shelfY: Int = 0
    private var shelfRowHeight: Int = 0
    private var dirtyRegion: DirtyRegion?

    /// Cached glyph metrics used by layout before a glyph is ever rasterized.
    private var metricsCache: [GlyphKey: GlyphMetrics] = [:]

    /// Cached atlas entries for glyphs that were already rasterized.
    private var rasterCache: [GlyphKey: GlyphInfo] = [:]

    /// Registered external FreeType faces for multi-font rendering.
    private var registeredFaces: [Int: RegisteredFace] = [:]
    private var colorSources: [Int: ColorGlyphSource] = [:]
    private var colorAtlas: ColorGlyphAtlas?

    /// Current font size in points.
    public private(set) var fontSize: Float = 0
    public private(set) var rasterScale: Float = 1

    // MARK: - Types

    private struct GlyphKey: Hashable {
        let fontID: Int
        let glyphIndex: UInt32
        let size: Float
        let rasterScale: Float
    }

    private struct RegisteredFace {
        let face: FT_Face
        let size: Float
        let rasterScale: Float
    }

    /// Metrics and atlas location for a single rasterized glyph.
    public typealias GlyphInfo = GuavaUICore.GlyphAtlasInfo

    /// Glyph metrics sufficient for layout without forcing bitmap generation.
    public typealias GlyphMetrics = GuavaUICore.GlyphMetrics

    public typealias LineMetrics = GuavaUICore.GlyphLineMetrics

    public struct DirtyRegion {
        public let x: Int
        public let y: Int
        public let width: Int
        public let height: Int

        public init(x: Int, y: Int, width: Int, height: Int) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
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
    @discardableResult
    public func loadFont(path: String, size: Float, rasterScale: Float = 1) -> Bool {
        if let face = ftFace {
            FT_Done_Face(face)
            ftFace = nil
        }

        var face: FT_Face?
        let err = FT_New_Face(ensureLibrary(), path, 0, &face)
        // A missing or unreadable font must never crash the app — leave the atlas
        // faceless so the caller can fall back to another font.
        guard err == 0, let face else { return false }
        self.ftFace = face
        self.fontSize = size
        self.rasterScale = max(1, rasterScale)

        FT_Set_Char_Size(face, 0, FT_F26Dot6(size * self.rasterScale * 64), 72, 72)

        atlasData = [UInt8](repeating: 0, count: atlasWidth * atlasHeight)
        shelfX = 0
        shelfY = 0
        shelfRowHeight = 0
        metricsCache.removeAll()
        rasterCache.removeAll()
        dirtyRegion = nil
        alphaIsDirty = false
        alphaIsFull = false
        colorAtlas?.reset()
        return true
    }

    /// Loads an owned copy of a TTF/OTF buffer, including fonts fetched by a
    /// browser. Invalid data leaves the current face and atlas untouched.
    @discardableResult
    public func loadFont(bytes: [UInt8], size: Float, rasterScale: Float = 1) -> Bool {
        guard !bytes.isEmpty, size.isFinite, size > 0, size <= 512,
              rasterScale.isFinite, rasterScale >= 1, rasterScale <= 4 else { return false }
        let storage = UnsafeMutablePointer<UInt8>.allocate(capacity: bytes.count)
        bytes.withUnsafeBufferPointer { storage.initialize(from: $0.baseAddress!, count: $0.count) }
        var face: FT_Face?
        guard FT_New_Memory_Face(ensureLibrary(), storage, FT_Long(bytes.count), 0, &face) == 0,
              let face else { storage.deallocate(); return false }
        guard FT_Set_Char_Size(face, 0, FT_F26Dot6(size * rasterScale * 64), 72, 72) == 0 else {
            FT_Done_Face(face); storage.deallocate(); return false
        }
        // HarfBuzz may retain a face across an atlas reload. Attach storage to
        // the face's finalizer, rather than releasing it with the current font.
        face.pointee.generic.data = UnsafeMutableRawPointer(storage)
        face.pointee.generic.finalizer = { object in
            guard let face = object?.assumingMemoryBound(to: FT_FaceRec.self) else { return }
            face.pointee.generic.data?.assumingMemoryBound(to: UInt8.self).deallocate()
        }
        if let old = ftFace { FT_Done_Face(old) }
        ftFace = face
        fontSize = size
        self.rasterScale = rasterScale
        metricsCache.removeAll()
        reset()
        return true
    }

    /// The underlying FreeType face (for HarfBuzz integration).
    public var freetypeFace: FT_Face? { ftFace }

    // MARK: - Multi-font registration

    /// Registers an external FreeType face for multi-font rasterization.
    ///
    /// The caller is responsible for keeping the face alive while the atlas uses it.
    public func registerFace(_ face: FT_Face,
                             fontID: Int,
                             size: Float? = nil,
                             rasterScale: Float? = nil) {
        registeredFaces[fontID] = RegisteredFace(
            face: face,
            size: size ?? fontSize,
            rasterScale: rasterScale ?? self.rasterScale
        )
    }

    private func resolveFace(fontID: Int) -> RegisteredFace? {
        if let registered = registeredFaces[fontID] { return registered }
        if fontID == 0, let ftFace {
            return RegisteredFace(face: ftFace, size: fontSize, rasterScale: rasterScale)
        }
        return nil
    }

    private func ensureLibrary() -> FT_Library {
        if let ftLibrary {
            return ftLibrary
        }

        var lib: FT_Library?
        let err = FT_Init_FreeType(&lib)
        precondition(err == 0, "FT_Init_FreeType failed: \(err)")
        self.ftLibrary = lib
        return lib!
    }

    public func glyphMetrics(glyphIndex: UInt32, fontID: Int = 0) -> GlyphMetrics? {
        if let source = colorSources[fontID] {
            let key = GlyphKey(fontID: fontID, glyphIndex: glyphIndex, size: source.size, rasterScale: source.rasterScale)
            if let cached = metricsCache[key] { return cached }
            let metrics = source.metrics(glyphIndex); metricsCache[key] = metrics; return metrics
        }
        guard let resolved = resolveFace(fontID: fontID) else { return nil }

        let scale = max(resolved.rasterScale, 1)
        let key = GlyphKey(
            fontID: fontID,
            glyphIndex: glyphIndex,
            size: resolved.size,
            rasterScale: scale
        )
        if let cached = metricsCache[key] { return cached }

        let face = resolved.face
        let loadFlags = FT_LOAD_DEFAULT | FT_Int32(FT_LOAD_COMPUTE_METRICS)
        let err = FT_Load_Glyph(face, FT_UInt(glyphIndex), loadFlags)
        guard err == 0, let glyphSlot = face.pointee.glyph else { return nil }

        let metrics = makeMetrics(glyphIndex: glyphIndex,
                                  glyphSlot: glyphSlot,
                                  scale: scale)
        metricsCache[key] = metrics
        return metrics
    }

    public func cachedGlyphInfo(glyphIndex: UInt32, fontID: Int = 0) -> GlyphInfo? {
        if let source = colorSources[fontID] {
            return rasterCache[GlyphKey(fontID: fontID, glyphIndex: glyphIndex, size: source.size, rasterScale: source.rasterScale)]
        }
        guard let resolved = resolveFace(fontID: fontID) else { return nil }

        let scale = max(resolved.rasterScale, 1)
        let key = GlyphKey(
            fontID: fontID,
            glyphIndex: glyphIndex,
            size: resolved.size,
            rasterScale: scale
        )
        return rasterCache[key]
    }

    public func lineMetrics(fontID: Int = 0) -> LineMetrics? {
        if let source = colorSources[fontID] { return source.lineMetrics() }
        guard let resolved = resolveFace(fontID: fontID),
              let size = resolved.face.pointee.size else { return nil }

        let scale = max(resolved.rasterScale, 1)
        let metrics = size.pointee.metrics
        let ascent = Float(metrics.ascender) / 64.0 / scale
        let descent = Float(-metrics.descender) / 64.0 / scale
        let lineHeight = Float(metrics.height) / 64.0 / scale

        guard ascent > 0 || descent > 0 || lineHeight > 0 else { return nil }
        return LineMetrics(ascent: ascent, descent: descent, lineHeight: lineHeight)
    }

    public func dirtyUploadPayload() -> (region: DirtyRegion, pixels: [UInt8])? {
        guard let dirtyRegion,
              dirtyRegion.width > 0,
              dirtyRegion.height > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: dirtyRegion.width * dirtyRegion.height)
        for row in 0..<dirtyRegion.height {
            let srcBase = (dirtyRegion.y + row) * atlasWidth + dirtyRegion.x
            let dstBase = row * dirtyRegion.width
            for col in 0..<dirtyRegion.width {
                pixels[dstBase + col] = atlasData[srcBase + col]
            }
        }
        return (dirtyRegion, pixels)
    }

    // MARK: - Glyph rasterization

    /// Rasterizes a glyph by its glyph index (not codepoint) and packs it into the atlas.
    ///
    /// - Parameters:
    ///   - glyphIndex: FreeType glyph index.
    ///   - fontID: Font identifier (0 = default/stored face, others = registered faces).
    /// - Returns: Cached or newly rasterized glyph info, or nil on failure.
    public func rasterizeGlyph(glyphIndex: UInt32, fontID: Int = 0) -> GlyphInfo? {
        if let source = colorSources[fontID] { return rasterizeColorGlyph(glyphIndex, fontID: fontID, source: source) }
        guard let resolved = resolveFace(fontID: fontID) else { return nil }

        let scale = max(resolved.rasterScale, 1)
        let key = GlyphKey(
            fontID: fontID,
            glyphIndex: glyphIndex,
            size: resolved.size,
            rasterScale: scale
        )
        if let cached = rasterCache[key] { return cached }

        let face = resolved.face

        // FT_LOAD_TARGET_LIGHT  = (1 & 15) << 16 = 0x10000: lighter vertical hinting,
        //                         smoother diagonal strokes at small sizes.
        // FT_LOAD_FORCE_AUTOHINT = 1 << 5 = 0x20: use FreeType autohinter instead of
        //                         native font hinting, which is generally better for
        //                         screen rendering of tool-chrome text (12-14 px).
        let renderFlags = FT_Int32(FT_LOAD_RENDER) | (1 << 5) | (1 << 16)
        let err = FT_Load_Glyph(face, FT_UInt(glyphIndex), renderFlags)
        guard err == 0 else { return nil }

        guard let glyphSlot = face.pointee.glyph else { return nil }
        let bitmap = glyphSlot.pointee.bitmap
        let w = Int(bitmap.width)
        let h = Int(bitmap.rows)
        let logicalWidth = Float(w) / scale
        let logicalHeight = Float(h) / scale
        let bearingX = Float(glyphSlot.pointee.bitmap_left) / scale
        let bearingY = Float(glyphSlot.pointee.bitmap_top) / scale
        let advance = Float(glyphSlot.pointee.advance.x) / 64.0 / scale

        // Pack into atlas using shelf algorithm
        let (x, y) = packGlyph(width: w, height: h)
        guard x >= 0 else {
            // Atlas full
            alphaIsFull = true
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
            width: logicalWidth,
            height: logicalHeight,
            bearingX: bearingX,
            bearingY: bearingY,
            advance: advance,
            uvMinX: Float(x) / Float(atlasWidth),
            uvMinY: Float(y) / Float(atlasHeight),
            uvMaxX: Float(x + w) / Float(atlasWidth),
            uvMaxY: Float(y + h) / Float(atlasHeight)
        )

        metricsCache[key] = GlyphMetrics(
            glyphIndex: glyphIndex,
            width: logicalWidth,
            height: logicalHeight,
            bearingX: bearingX,
            bearingY: bearingY,
            advance: advance
        )
        rasterCache[key] = info
        if w > 0, h > 0 {
            mergeDirtyRegion(x: x, y: y, width: w, height: h)
        }
        alphaIsDirty = true
        return info
    }

    /// Rasterizes a glyph by Unicode codepoint. Convenience wrapper over `rasterizeGlyph(glyphIndex:fontID:)`.
    public func rasterizeCodepoint(_ codepoint: UInt32, fontID: Int = 0) -> GlyphInfo? {
        guard let resolved = resolveFace(fontID: fontID) else { return nil }
        let glyphIndex = FT_Get_Char_Index(resolved.face, FT_ULong(codepoint))
        guard glyphIndex != 0 else { return nil }
        return rasterizeGlyph(glyphIndex: glyphIndex, fontID: fontID)
    }

    /// Clears the atlas bitmap and raster cache. Keeps the loaded font and
    /// cached metrics so future layout passes stay cheap.
    public func reset() {
        colorAtlas?.reset()
        alphaIsFull = false
        atlasData = [UInt8](repeating: 0, count: atlasWidth * atlasHeight)
        rasterCache.removeAll()
        shelfX = 0
        shelfY = 0
        shelfRowHeight = 0
        dirtyRegion = DirtyRegion(x: 0, y: 0, width: atlasWidth, height: atlasHeight)
        alphaIsDirty = true
    }

    public func markClean() {
        colorAtlas?.markClean()
        alphaIsDirty = false
        dirtyRegion = nil
    }

    public func registerColorSource(_ source: ColorGlyphSource, fontID: Int) {
        colorSources[fontID] = source
    }

    public func colorDirtyUploadPayload() -> (region: DirtyRegion, pixels: [UInt8], textureWidth: Int, textureHeight: Int)? {
        guard let colorAtlas, let payload = colorAtlas.payload() else { return nil }
        return (payload.region, payload.pixels, colorAtlas.width, colorAtlas.height)
    }

    private func rasterizeColorGlyph(_ glyphIndex: UInt32, fontID: Int, source: ColorGlyphSource) -> GlyphInfo? {
        let key = GlyphKey(fontID: fontID, glyphIndex: glyphIndex, size: source.size, rasterScale: source.rasterScale)
        if let cached = rasterCache[key] { return cached }
        guard let bitmap = source.rasterize(glyphIndex) else { return nil }
        if colorAtlas == nil { colorAtlas = ColorGlyphAtlas(width: atlasWidth, height: atlasHeight) }
        guard let info = colorAtlas?.insert(bitmap) else { return nil }
        metricsCache[key] = bitmap.metrics; rasterCache[key] = info
        return info
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

    private func mergeDirtyRegion(x: Int, y: Int, width: Int, height: Int) {
        let next = DirtyRegion(x: x, y: y, width: width, height: height)
        guard let dirtyRegion else {
            dirtyRegion = next
            return
        }

        let minX = min(dirtyRegion.x, next.x)
        let minY = min(dirtyRegion.y, next.y)
        let maxX = max(dirtyRegion.x + dirtyRegion.width, next.x + next.width)
        let maxY = max(dirtyRegion.y + dirtyRegion.height, next.y + next.height)
        self.dirtyRegion = DirtyRegion(x: minX,
                                       y: minY,
                                       width: maxX - minX,
                                       height: maxY - minY)
    }

    private func makeMetrics(glyphIndex: UInt32,
                             glyphSlot: FT_GlyphSlot,
                             scale: Float) -> GlyphMetrics {
        var width = Float(glyphSlot.pointee.metrics.width) / 64.0 / scale
        var height = Float(glyphSlot.pointee.metrics.height) / 64.0 / scale
        var bearingX = Float(glyphSlot.pointee.metrics.horiBearingX) / 64.0 / scale
        var bearingY = Float(glyphSlot.pointee.metrics.horiBearingY) / 64.0 / scale
        let advance = Float(glyphSlot.pointee.advance.x) / 64.0 / scale

        var glyph: FT_Glyph?
        if FT_Get_Glyph(glyphSlot, &glyph) == 0, let glyph {
            var box = FT_BBox()
            FT_Glyph_Get_CBox(glyph, FT_UInt(FT_GLYPH_BBOX_PIXELS.rawValue), &box)
            width = Float(box.xMax - box.xMin) / scale
            height = Float(box.yMax - box.yMin) / scale
            bearingX = Float(box.xMin) / scale
            bearingY = Float(box.yMax) / scale
            FT_Done_Glyph(glyph)
        }

        return GlyphMetrics(
            glyphIndex: glyphIndex,
            width: width,
            height: height,
            bearingX: bearingX,
            bearingY: bearingY,
            advance: advance
        )
    }
}

extension FontAtlas: GlyphMetricsProvider {}
