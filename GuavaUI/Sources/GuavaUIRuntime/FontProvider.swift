import CoreText
import Foundation
import CFreeType
import CHarfBuzz

/// A font loaded via CoreText, with FreeType face and HarfBuzz font ready for use.
public final class ManagedFont {
    /// Unique identifier within the owning FontProvider.
    public let id: Int
    /// PostScript name (e.g. ".SFNS-Regular", "PingFangSC-Regular").
    public let postScriptName: String
    internal let ftFace: FT_Face
    internal let hbFont: OpaquePointer  // hb_font_t*

    // Pinned buffer — must stay alive as long as ftFace.
    private let buffer: UnsafeMutablePointer<UInt8>
    private let bufferSize: Int

    init(id: Int, postScriptName: String, ftFace: FT_Face, hbFont: OpaquePointer,
         buffer: UnsafeMutablePointer<UInt8>, bufferSize: Int) {
        self.id = id
        self.postScriptName = postScriptName
        self.ftFace = ftFace
        self.hbFont = hbFont
        self.buffer = buffer
        self.bufferSize = bufferSize
    }

    deinit {
        hb_font_destroy(hbFont)
        FT_Done_Face(ftFace)
        buffer.deallocate()
    }
}

/// A contiguous text segment that should be shaped with a specific font.
public struct FontRun {
    /// Font for this segment.
    public let font: ManagedFont
    /// The text substring.
    public let text: String
    /// Byte offset of this segment in the original string's UTF-8 representation.
    public let utf8Offset: Int
}

/// Resolves fonts via CoreText and provides automatic fallback for any script.
///
/// CoreText determines which system font covers each character range,
/// then loads the corresponding FreeType face and HarfBuzz font for shaping.
public final class FontProvider {
    private let ftLibrary: FT_Library
    private var fonts: [String: ManagedFont] = [:]
    private var nextFontID: Int = 0
    private let size: Float
    private var primaryPSName: String?

    /// Creates a FontProvider with the given font size.
    public init(size: Float) {
        var lib: FT_Library?
        let err = FT_Init_FreeType(&lib)
        precondition(err == 0, "FT_Init_FreeType failed: \(err)")
        self.ftLibrary = lib!
        self.size = size
    }

    deinit {
        fonts.removeAll()
        FT_Done_FreeType(ftLibrary)
    }

    /// The primary font, if loaded.
    public var primaryFont: ManagedFont? {
        guard let name = primaryPSName else { return nil }
        return fonts[name]
    }

    /// All currently loaded fonts.
    public var allFonts: [ManagedFont] { Array(fonts.values) }

    /// Registers all loaded fonts into the given atlas for multi-font rasterization.
    public func registerAllFonts(in atlas: FontAtlas) {
        for font in fonts.values {
            atlas.registerFace(font.ftFace, fontID: font.id)
        }
    }

    /// Loads the primary font by family name or PostScript name.
    @discardableResult
    public func loadPrimaryFont(name: String) -> ManagedFont? {
        let font = loadFontByName(name)
        if let font {
            primaryPSName = font.postScriptName
        }
        return font
    }

    // MARK: - Font fallback

    /// Splits text into runs, each assigned the system font that can render it.
    ///
    /// Uses CoreText's typographic layout engine to determine font coverage.
    /// Fallback fonts (e.g. PingFang SC for CJK, Apple Color Emoji for emoji)
    /// are loaded into FreeType automatically on first encounter.
    public func resolveRuns(text: String) -> [FontRun] {
        guard !text.isEmpty, let primaryPSName else { return [] }

        let ctPrimary = CTFontCreateWithName(primaryPSName as CFString, CGFloat(size), nil)
        let attrs = [kCTFontAttributeName: ctPrimary] as CFDictionary
        let attrStr = CFAttributedStringCreate(kCFAllocatorDefault, text as CFString, attrs)!
        let line = CTLineCreateWithAttributedString(attrStr)
        let glyphRuns = CTLineGetGlyphRuns(line) as! [CTRun]

        let nsStr = text as NSString
        var result: [FontRun] = []

        for run in glyphRuns {
            let runAttrs = CTRunGetAttributes(run) as NSDictionary
            let runCTFont = runAttrs[kCTFontAttributeName as NSString] as! CTFont
            let psName = CTFontCopyPostScriptName(runCTFont) as String

            let cfRange = CTRunGetStringRange(run)
            let runText = nsStr.substring(with: NSRange(location: cfRange.location, length: cfRange.length))
            let utf8Offset = nsStr.substring(to: cfRange.location).utf8.count

            let managedFont: ManagedFont
            if let existing = fonts[psName] {
                managedFont = existing
            } else if let loaded = loadFontFromCTFont(runCTFont, psName: psName) {
                managedFont = loaded
            } else {
                continue
            }

            result.append(FontRun(font: managedFont, text: runText, utf8Offset: utf8Offset))
        }

        return result
    }

    // MARK: - Shaping

    /// Shapes a font run using HarfBuzz with auto-detected script/language.
    ///
    /// Cluster values in the returned glyphs are adjusted by the run's `utf8Offset`
    /// so they map back to the original (pre-split) string.
    public func shapeRun(_ run: FontRun) -> [ShapedGlyph] {
        guard let buf = hb_buffer_create() else { return [] }
        defer { hb_buffer_destroy(buf) }

        run.text.withCString(encodedAs: UTF8.self) { ptr in
            hb_buffer_add_utf8(buf, ptr, Int32(run.text.utf8.count), 0, Int32(run.text.utf8.count))
        }

        hb_buffer_guess_segment_properties(buf)
        hb_shape(run.font.hbFont, buf, nil, 0)

        var glyphCount: UInt32 = 0
        guard let infos = hb_buffer_get_glyph_infos(buf, &glyphCount),
              let positions = hb_buffer_get_glyph_positions(buf, &glyphCount) else { return [] }

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
                cluster: info.cluster + UInt32(run.utf8Offset),
                fontID: run.font.id
            ))
        }

        return result
    }

    // MARK: - Private

    private func loadFontByName(_ name: String) -> ManagedFont? {
        let ctFont = CTFontCreateWithName(name as CFString, CGFloat(size), nil)
        let psName = CTFontCopyPostScriptName(ctFont) as String
        if let existing = fonts[psName] { return existing }
        return loadFontFromCTFont(ctFont, psName: psName)
    }

    private func loadFontFromCTFont(_ ctFont: CTFont, psName: String) -> ManagedFont? {
        if let existing = fonts[psName] { return existing }

        let descriptor = CTFontCopyFontDescriptor(ctFont)
        guard let urlRef = CTFontDescriptorCopyAttribute(descriptor, kCTFontURLAttribute),
              let url = urlRef as? URL else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }

        let faceIndex = findFaceIndex(in: data, targetPSName: psName)

        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
        data.copyBytes(to: buffer, count: data.count)

        var face: FT_Face?
        let err = FT_New_Memory_Face(ftLibrary, buffer, FT_Long(data.count), FT_Long(faceIndex), &face)
        guard err == 0, let ftFace = face else {
            buffer.deallocate()
            return nil
        }

        FT_Set_Char_Size(ftFace, 0, FT_F26Dot6(size * 64), 72, 72)

        guard let hbFont = hb_ft_font_create_referenced(ftFace) else {
            FT_Done_Face(ftFace)
            buffer.deallocate()
            return nil
        }

        let id = nextFontID
        nextFontID += 1

        let managed = ManagedFont(
            id: id, postScriptName: psName, ftFace: ftFace, hbFont: hbFont,
            buffer: buffer, bufferSize: data.count
        )
        fonts[psName] = managed
        return managed
    }

    /// Finds the face index within a TTC/OTC collection that matches the target PostScript name.
    private func findFaceIndex(in data: Data, targetPSName: String) -> Int {
        let probe = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
        data.copyBytes(to: probe, count: data.count)
        defer { probe.deallocate() }

        var face: FT_Face?
        let err = FT_New_Memory_Face(ftLibrary, probe, FT_Long(data.count), 0, &face)
        guard err == 0, let f = face else { return 0 }
        let numFaces = Int(f.pointee.num_faces)

        if let namePtr = FT_Get_Postscript_Name(f), String(cString: namePtr) == targetPSName {
            FT_Done_Face(f)
            return 0
        }
        FT_Done_Face(f)

        guard numFaces > 1 else { return 0 }

        for i in 1..<numFaces {
            var fi: FT_Face?
            let e = FT_New_Memory_Face(ftLibrary, probe, FT_Long(data.count), FT_Long(i), &fi)
            guard e == 0, let ff = fi else { continue }
            defer { FT_Done_Face(ff) }

            if let namePtr = FT_Get_Postscript_Name(ff), String(cString: namePtr) == targetPSName {
                return i
            }
        }

        return 0
    }
}
