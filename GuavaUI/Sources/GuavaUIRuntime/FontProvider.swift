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
        fonts.removeAll()
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
        // On non-Apple platforms, return a single run with the primary font.
        guard !text.isEmpty, let name = primaryPSName, let font = fonts[name] else { return [] }
        return [FontRun(font: font, text: text, utf8Offset: 0)]
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
        // Try bundled Inter font first
        if let url = BundledFonts.bundledFontURL,
           let data = try? Data(contentsOf: url) {
            let psName = name.isEmpty ? "Inter-Regular" : name
            return loadFontFromData(data, psName: psName, faceIndex: 0)
        }
        // Fallback: try common system font directories
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
        return nil
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

    private func managedFontCanRenderText(_ font: ManagedFont, text: String) -> Bool {
        guard !text.isEmpty else { return true }
        return text.unicodeScalars.allSatisfy { scalar in
            FT_Get_Char_Index(font.ftFace, FT_ULong(scalar.value)) != 0
        }
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
