import Foundation
import CFreeType
import CHarfBuzz
import GuavaUIBundledFonts
#if canImport(CoreText)
import CoreText
#endif

/// A font loaded via FreeType, with HarfBuzz font ready for use.
public final class ManagedFont {
    public let id: Int
    public let postScriptName: String
    public let pointSize: Float
    public let rasterScale: Float
    internal let ftFace: FT_Face
    internal let hbFont: OpaquePointer  // hb_font_t*

    public var rawFace: FT_Face { ftFace }

    // Pinned buffer — must stay alive as long as ftFace.
    private let buffer: UnsafeMutablePointer<UInt8>
    private let bufferSize: Int

    init(id: Int, postScriptName: String, pointSize: Float, rasterScale: Float,
            ftFace: FT_Face, hbFont: OpaquePointer,
         buffer: UnsafeMutablePointer<UInt8>, bufferSize: Int) {
        self.id = id
        self.postScriptName = postScriptName
        self.pointSize = pointSize
        self.rasterScale = rasterScale
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
    public let font: ManagedFont
    public let text: String
    public let utf8Offset: Int
}

/// Resolves fonts and provides shaping for text runs.
///
/// On Apple platforms: uses CoreText for font discovery and fallback.
/// On Windows/Linux: loads fonts directly from file paths using FreeType.
public final class FontProvider {
    private let ftLibrary: FT_Library
    private var fonts: [String: ManagedFont] = [:]
    private var nextFontID: Int = 0
    private let size: Float
    private let rasterScale: Float
    private var primaryPSName: String?

#if canImport(CoreText)
    private var primaryCTFont: CTFont?
#else
    // Lazily-loaded system fallback faces (CJK etc.) and the paths still to try.
    private var fallbackChain: [ManagedFont] = []
    private var triedFallbackPaths: Set<String> = []
    private lazy var fallbackFontPaths: [String] = Self.systemFallbackFontPaths()
#endif

    public init(size: Float, rasterScale: Float = 1, idBase: Int = 0) {
        var lib: FT_Library?
        let err = FT_Init_FreeType(&lib)
        precondition(err == 0, "FT_Init_FreeType failed: \(err)")
        self.ftLibrary = lib!
        self.size = size
        self.rasterScale = max(1, rasterScale)
        self.nextFontID = idBase
    }

    deinit {
        // Every face must be released before the library: a ManagedFont still
        // held by `fallbackChain` would otherwise run FT_Done_Face against an
        // already-freed FT_Library (use-after-free).
        fonts.removeAll()
#if !canImport(CoreText)
        fallbackChain.removeAll()
#endif
        FT_Done_FreeType(ftLibrary)
    }

    public var primaryFont: ManagedFont? {
        guard let name = primaryPSName else { return nil }
        return fonts[name]
    }

    public var allFonts: [ManagedFont] { Array(fonts.values) }

    public func registerAllFonts(in atlas: FontAtlas) {
        for font in fonts.values {
            atlas.registerFace(
                font.ftFace,
                fontID: font.id,
                size: font.pointSize,
                rasterScale: font.rasterScale
            )
        }
    }

    @discardableResult
    public func loadPrimaryFont(name: String,
                                weight: FontWeight = .regular) -> ManagedFont? {
#if canImport(CoreText)
        let ctFont = configuredCTFont(named: name, weight: weight)
        let font = loadFont(ctFont)
        if let font {
            primaryPSName = font.postScriptName
            primaryCTFont = ctFont
        }
        return font
#else
        return loadPrimaryFontDirect(name: name)
#endif
    }

    // MARK: - Font fallback

    /// Splits text into runs, each assigned the font that can render it.
    public func resolveRuns(text: String) -> [FontRun] {
#if canImport(CoreText)
        guard !text.isEmpty, let ctPrimary = primaryCTFont else { return [] }
        var result: [FontRun] = []

        let nsText = text as NSString
        var currentFont: ManagedFont?
        var currentPSName: String?
        var currentText = ""
        var currentUTF8Offset = 0
        var runningUTF8Offset = 0

        func flushCurrentRun() {
            guard let currentFont, !currentText.isEmpty else { return }
            result.append(FontRun(font: currentFont, text: currentText, utf8Offset: currentUTF8Offset))
            currentText = ""
        }

        nsText.enumerateSubstrings(in: NSRange(location: 0, length: nsText.length),
                                   options: .byComposedCharacterSequences) { substring, range, _, _ in
            guard let substring else { return }

            guard let managedFont = self.coveringManagedFont(for: substring,
                                                             in: text,
                                                             range: range,
                                                             primary: ctPrimary) else {
                runningUTF8Offset += substring.utf8.count
                return
            }
            let psName = managedFont.postScriptName

            if currentPSName != psName {
                flushCurrentRun()
                currentFont = managedFont
                currentPSName = psName
                currentUTF8Offset = runningUTF8Offset
            }

            currentText += substring
            runningUTF8Offset += substring.utf8.count
        }

        flushCurrentRun()

        return result
#else
        // Off Apple there is no CoreText cascade, so walk the text by grapheme
        // cluster and route each to the primary font or, when the primary lacks
        // the glyph (e.g. CJK in the Latin bundled face), a lazily-loaded system
        // fallback. Consecutive clusters sharing a font are merged into one run.
        guard !text.isEmpty,
              let primaryName = primaryPSName,
              let primary = fonts[primaryName] else { return [] }

        var result: [FontRun] = []
        var currentFont: ManagedFont?
        var currentText = ""
        var currentUTF8Offset = 0
        var runningUTF8Offset = 0

        func flushCurrentRun() {
            guard let currentFont, !currentText.isEmpty else { return }
            result.append(FontRun(font: currentFont, text: currentText, utf8Offset: currentUTF8Offset))
            currentText = ""
        }

        for character in text {
            let cluster = String(character)
            let font = fallbackFont(for: cluster, primary: primary)
            if currentFont?.id != font.id {
                flushCurrentRun()
                currentFont = font
                currentUTF8Offset = runningUTF8Offset
            }
            currentText += cluster
            runningUTF8Offset += cluster.utf8.count
        }

        flushCurrentRun()
        return result
#endif
    }

    // MARK: - Shaping

    public func shapeRun(_ run: FontRun) -> [ShapedGlyph] {
        guard let buf = hb_buffer_create() else { return [] }
        defer { hb_buffer_destroy(buf) }
        let scale = max(run.font.rasterScale, 1)

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
                xOffset: Float(pos.x_offset) / 64.0 / scale,
                yOffset: Float(pos.y_offset) / 64.0 / scale,
                xAdvance: Float(pos.x_advance) / 64.0 / scale,
                yAdvance: Float(pos.y_advance) / 64.0 / scale,
                cluster: info.cluster + UInt32(run.utf8Offset),
                fontID: run.font.id
            ))
        }

        return result
    }

    // MARK: - Direct file loading (non-Apple)

#if !canImport(CoreText)
    private func loadPrimaryFontDirect(name: String) -> ManagedFont? {
        // 1. If `name` happens to match a font file by basename, load it.
        if !name.isEmpty {
            let extensions = ["ttc", "ttf", "otf"]
            let systemDirs = [
                "C:\\Windows\\Fonts\\",
                "/usr/share/fonts/",
                "/usr/local/share/fonts/",
            ]
            for dir in systemDirs {
                for ext in extensions {
                    let path = dir + name + "." + ext
                    if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                        return loadFontFromData(data, psName: name, faceIndex: 0)
                    }
                }
            }
        }
        // 2. Fall back to the platform's default UI font (Segoe UI on Windows,
        //    a common sans on Linux). The system pairs this with its own CJK
        //    fallback (e.g. YaHei) so mixed scripts stay visually consistent.
        for path in Self.systemPrimaryFontPaths() {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                return loadFontFromData(data,
                                        psName: name.isEmpty ? "system-ui" : name,
                                        faceIndex: 0)
            }
        }
        return nil
    }

    /// Path(s) to the platform's default UI font, used as the primary face on
    /// non-Apple platforms now that no font is bundled. Probed in order.
    private static func systemPrimaryFontPaths() -> [String] {
#if os(Windows)
        let dir = "C:\\Windows\\Fonts\\"
        return [
            "segoeui.ttf",   // Segoe UI — the Windows shell UI font
            "tahoma.ttf",
            "arial.ttf",
        ].map { dir + $0 }
#elseif os(Linux)
        return [
            "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
            "/usr/share/fonts/TTF/DejaVuSans.ttf",
            "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
            "/usr/share/fonts/noto/NotoSans-Regular.ttf",
            "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
            "/usr/share/fonts/liberation/LiberationSans-Regular.ttf",
            "/usr/share/fonts/truetype/freefont/FreeSans.ttf",
        ]
#else
        return []
#endif
    }

    private func loadFontFromData(_ data: Data, psName: String, faceIndex: Int) -> ManagedFont? {
        if let existing = fonts[psName] { return existing }

        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
        data.copyBytes(to: buffer, count: data.count)

        var face: FT_Face?
        let err = FT_New_Memory_Face(ftLibrary, buffer, FT_Long(data.count), FT_Long(faceIndex), &face)
        guard err == 0, let ftFace = face else {
            buffer.deallocate()
            return nil
        }

        _ = FT_Select_Charmap(ftFace, FT_ENCODING_UNICODE)
        FT_Set_Char_Size(ftFace, 0, FT_F26Dot6(size * rasterScale * 64), 72, 72)

        guard let hbFont = hb_ft_font_create_referenced(ftFace) else {
            FT_Done_Face(ftFace)
            buffer.deallocate()
            return nil
        }

        let id = nextFontID
        nextFontID += 1

        let resolvedPSName: String
        if let namePtr = FT_Get_Postscript_Name(ftFace) {
            resolvedPSName = String(cString: namePtr)
        } else {
            resolvedPSName = psName
        }

        let managed = ManagedFont(
            id: id, postScriptName: resolvedPSName, pointSize: size, rasterScale: rasterScale,
            ftFace: ftFace, hbFont: hbFont,
            buffer: buffer, bufferSize: data.count
        )
        fonts[resolvedPSName] = managed
        fonts[psName] = managed
        if primaryPSName == nil { primaryPSName = resolvedPSName }
        return managed
    }

    // MARK: - Non-Apple font fallback

    /// Resolves the face that should render `cluster`: the primary when it has
    /// the glyph, otherwise a system fallback (loaded on first need), or the
    /// primary as a last resort (renders .notdef rather than dropping the text).
    private func fallbackFont(for cluster: String, primary: ManagedFont) -> ManagedFont {
        if managedFontCanRenderText(primary, text: cluster) { return primary }

        for font in fallbackChain where managedFontCanRenderText(font, text: cluster) {
            return font
        }

        for path in fallbackFontPaths where !triedFallbackPaths.contains(path) {
            triedFallbackPaths.insert(path)
            guard let font = loadFallbackFont(path: path) else { continue }
            fallbackChain.append(font)
            if managedFontCanRenderText(font, text: cluster) { return font }
        }

        return primary
    }

    private func loadFallbackFont(path: String) -> ManagedFont? {
        let cacheKey = "fallback:" + path
        if let existing = fonts[cacheKey] { return existing }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return loadFontFromData(data, psName: cacheKey, faceIndex: 0)
    }

    /// System faces that, together, cover CJK / common non-Latin scripts the
    /// bundled Latin primary lacks. Probed in order; the first that resolves a
    /// given cluster wins.
    private static func systemFallbackFontPaths() -> [String] {
#if os(Windows)
        let dir = "C:\\Windows\\Fonts\\"
        return [
            "msyh.ttc",      // Microsoft YaHei — Simplified Chinese
            "msyhl.ttc",
            "simsun.ttc",    // SimSun
            "msjh.ttc",      // Microsoft JhengHei — Traditional Chinese
            "msgothic.ttc",  // MS Gothic — Japanese
            "yugothm.ttc",
            "malgun.ttf",    // Malgun Gothic — Korean
            "seguiemj.ttf",  // Segoe UI Emoji
            "arial.ttf",
        ].map { dir + $0 }
#elseif os(Linux)
        return [
            "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
            "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc",
            "/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc",
            "/usr/share/fonts/google-noto-cjk/NotoSansCJK-Regular.ttc",
            "/usr/share/fonts/opentype/noto/NotoSerifCJK-Regular.ttc",
            "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc",
            "/usr/share/fonts/truetype/wqy/wqy-microhei.ttc",
            "/usr/share/fonts/truetype/droid/DroidSansFallbackFull.ttf",
            "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        ]
#else
        return []
#endif
    }
#endif

    // MARK: - Apple CoreText-based loading

#if canImport(CoreText)
    private func loadFont(_ ctFont: CTFont) -> ManagedFont? {
        let psName = CTFontCopyPostScriptName(ctFont) as String
        if let existing = fonts[psName] { return existing }
        return loadFontFromCTFont(ctFont, psName: psName)
    }

    private func coveringManagedFont(for substring: String,
                                     in fullText: String,
                                     range: NSRange,
                                     primary: CTFont) -> ManagedFont? {
        let scaledSize = CGFloat(size * rasterScale)
        let direct = CTFontCreateForString(primary,
                                           fullText as CFString,
                                           CFRange(location: range.location, length: range.length))

        var candidates: [CTFont] = [direct, primary]
        candidates.append(contentsOf: SystemFontDefaults.fontStack.map {
            CTFontCreateWithName($0 as CFString, scaledSize, nil)
        })

        var seenPostScriptNames: Set<String> = []
        for candidate in candidates {
            let psName = CTFontCopyPostScriptName(candidate) as String
            guard seenPostScriptNames.insert(psName).inserted else { continue }
            guard let managedFont = loadFont(candidate) else { continue }
            if managedFontCanRenderText(managedFont, text: substring) {
                return managedFont
            }
        }

        return nil
    }

    private func loadFontFromCTFont(_ ctFont: CTFont, psName: String) -> ManagedFont? {
        if let existing = fonts[psName] { return existing }

        if let loaded = makeManagedFont(from: ctFont, cacheAliases: [psName]) {
            return loaded
        }

        for candidateName in fallbackPostScriptCandidates(for: ctFont, requestedPSName: psName) {
            if let existing = fonts[candidateName] {
                fonts[psName] = existing
                return existing
            }

            let candidateCTFont = CTFontCreateWithName(candidateName as CFString,
                                                       CGFloat(size * rasterScale),
                                                       nil)
            if let loaded = makeManagedFont(from: candidateCTFont,
                                            cacheAliases: [psName, candidateName]) {
                return loaded
            }
        }

        return nil
    }

    private func makeManagedFont(from ctFont: CTFont,
                                 cacheAliases: [String]) -> ManagedFont? {
        let actualPSName = CTFontCopyPostScriptName(ctFont) as String
        if let existing = fonts[actualPSName] {
            for alias in cacheAliases {
                fonts[alias] = existing
            }
            return existing
        }

        let descriptor = CTFontCopyFontDescriptor(ctFont)
        guard let urlRef = CTFontDescriptorCopyAttribute(descriptor, kCTFontURLAttribute),
              let url = urlRef as? URL else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }

        let resolvedFaceIndex = findFaceIndex(in: data, targetPSName: actualPSName)
            ?? descriptorFaceIndex(at: url, targetPSName: actualPSName)
        let faceIndex = resolvedFaceIndex ?? 0

        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
        data.copyBytes(to: buffer, count: data.count)

        var face: FT_Face?
        let err = FT_New_Memory_Face(ftLibrary, buffer, FT_Long(data.count), FT_Long(faceIndex), &face)
        guard err == 0, let ftFace = face else {
            buffer.deallocate()
            return nil
        }

        if resolvedFaceIndex == nil,
           let loadedNamePtr = FT_Get_Postscript_Name(ftFace) {
            let loadedPSName = String(cString: loadedNamePtr)
            if loadedPSName != actualPSName {
                FT_Done_Face(ftFace)
                buffer.deallocate()
                return nil
            }
        }

        _ = FT_Select_Charmap(ftFace, FT_ENCODING_UNICODE)
        FT_Set_Char_Size(ftFace, 0, FT_F26Dot6(size * rasterScale * 64), 72, 72)

        guard let hbFont = hb_ft_font_create_referenced(ftFace) else {
            FT_Done_Face(ftFace)
            buffer.deallocate()
            return nil
        }

        let id = nextFontID
        nextFontID += 1

        let managed = ManagedFont(
            id: id, postScriptName: actualPSName, pointSize: size, rasterScale: rasterScale,
            ftFace: ftFace, hbFont: hbFont,
            buffer: buffer, bufferSize: data.count
        )
        for alias in Set(cacheAliases + [actualPSName]) {
            fonts[alias] = managed
        }
        return managed
    }

    private func configuredCTFont(named name: String,
                                  weight: FontWeight) -> CTFont {
        let scaledSize = CGFloat(size * rasterScale)
        let base: CTFont
        if name == ".AppleSystemUIFont" {
            base = CTFontCreateUIFontForLanguage(.system, scaledSize, nil)
                ?? CTFontCreateWithName("Helvetica Neue" as CFString, scaledSize, nil)
        } else {
            base = CTFontCreateWithName(name as CFString, scaledSize, nil)
        }
        guard weight != .regular else { return base }

        let attrs: [CFString: Any] = [
            kCTFontTraitsAttribute: [kCTFontWeightTrait: weight.coreTextWeight]
        ]
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(
            CTFontCopyFontDescriptor(base),
            attrs as CFDictionary
        )
        return CTFontCreateWithFontDescriptor(descriptor, scaledSize, nil)
    }

    private func fallbackPostScriptCandidates(for ctFont: CTFont,
                                              requestedPSName: String) -> [String] {
        var candidates: [String] = []

        appendCandidate(normalizedFallbackPostScriptName(requestedPSName), to: &candidates)

        if let subfamily = CTFontCopyName(ctFont, kCTFontSubFamilyNameKey) as String? {
            let normalizedFamily = normalizedFallbackFamilyName(CTFontCopyFamilyName(ctFont) as String)
            let normalizedStyle = subfamily.replacingOccurrences(of: " ", with: "")
            if !normalizedFamily.isEmpty {
                let familyCandidate = normalizedStyle.isEmpty
                    ? normalizedFamily
                    : "\(normalizedFamily)-\(normalizedStyle)"
                appendCandidate(familyCandidate, to: &candidates)
            }
        }

        return candidates
    }

    private func normalizedFallbackPostScriptName(_ name: String) -> String {
        var normalized = name
        if normalized.hasPrefix(".") {
            normalized.removeFirst()
        }
        normalized = normalized.replacingOccurrences(of: "PingFangUIText", with: "PingFang")
        normalized = normalized.replacingOccurrences(of: "PingFangUI", with: "PingFang")
        return normalized
    }

    private func normalizedFallbackFamilyName(_ familyName: String) -> String {
        var normalized = familyName
        if normalized.hasPrefix(".") {
            normalized.removeFirst()
        }
        normalized = normalized.replacingOccurrences(of: "PingFang UI", with: "PingFang ")
        normalized = normalized.replacingOccurrences(of: " UI ", with: " ")
        normalized = normalized.replacingOccurrences(of: " UI", with: " ")
        normalized = normalized.replacingOccurrences(of: " ", with: "")
        return normalized
    }

    private func appendCandidate(_ candidate: String, to candidates: inout [String]) {
        guard !candidate.isEmpty, !candidates.contains(candidate) else { return }
        candidates.append(candidate)
    }

    private func descriptorFaceIndex(at url: URL,
                                     targetPSName: String) -> Int? {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] else {
            return nil
        }
        return descriptors.firstIndex(where: {
            (CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String) == targetPSName
        })
    }
#endif

    // MARK: - FreeType utilities (shared)

    /// True when `font` has a glyph for every scalar in `text` (a missing glyph
    /// maps to index 0 / .notdef in FreeType).
    private func managedFontCanRenderText(_ font: ManagedFont, text: String) -> Bool {
        guard !text.isEmpty else { return true }
        return text.unicodeScalars.allSatisfy { scalar in
            FT_Get_Char_Index(font.ftFace, FT_ULong(scalar.value)) != 0
        }
    }

    private func findFaceIndex(in data: Data, targetPSName: String) -> Int? {
        let probe = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
        data.copyBytes(to: probe, count: data.count)
        defer { probe.deallocate() }

        var face: FT_Face?
        let err = FT_New_Memory_Face(ftLibrary, probe, FT_Long(data.count), 0, &face)
        guard err == 0, let f = face else { return nil }
        let numFaces = Int(f.pointee.num_faces)

        if let namePtr = FT_Get_Postscript_Name(f), String(cString: namePtr) == targetPSName {
            FT_Done_Face(f)
            return 0
        }
        FT_Done_Face(f)

        guard numFaces > 1 else { return nil }

        for i in 1..<numFaces {
            var fi: FT_Face?
            let e = FT_New_Memory_Face(ftLibrary, probe, FT_Long(data.count), FT_Long(i), &fi)
            guard e == 0, let ff = fi else { continue }
            defer { FT_Done_Face(ff) }

            if let namePtr = FT_Get_Postscript_Name(ff), String(cString: namePtr) == targetPSName {
                return i
            }
        }

        return nil
    }
}
