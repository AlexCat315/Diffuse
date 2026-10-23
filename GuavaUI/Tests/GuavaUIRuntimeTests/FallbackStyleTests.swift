#if canImport(CoreText)
import CoreText
import Testing
@testable import GuavaUIRuntime

@Suite("Font fallback keeps the requested style")
struct FallbackStyleTests {
    private func fallbackName(weight: FontWeight, isItalic: Bool = false) -> String? {
        let provider = FontProvider(size: 14)
        _ = provider.loadPrimaryFont(name: ".AppleSystemUIFont", weight: weight, isItalic: isItalic)
        return provider.resolveRuns(text: "ab粗体").last?.font.postScriptName
    }

    /// Faces name weights differently (PingFang "Semibold", Hiragino "W6"),
    /// so compare the weight CoreText reports instead of the name.
    private func weight(of postScriptName: String) -> Double {
        let font = CTFontCreateWithName(postScriptName as CFString, 14, nil)
        let traits = CTFontCopyTraits(font) as? [CFString: Any] ?? [:]
        return (traits[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? 0
    }

    @Test("Reloading the primary font refreshes the cached fallback style")
    func primaryStyleChange() throws {
        let provider = FontProvider(size: 14)
        _ = try #require(provider.loadPrimaryFont(name: ".AppleSystemUIFont", weight: .regular))
        let regular = try #require(provider.resolveRuns(text: "ab粗体").last?.font)
        _ = try #require(provider.loadPrimaryFont(name: ".AppleSystemUIFont", weight: .bold))
        let bold = try #require(provider.resolveRuns(text: "ab粗体").last?.font)
        #expect(weight(of: bold.postScriptName) > weight(of: regular.postScriptName))
        _ = try #require(provider.loadPrimaryFont(name: ".AppleSystemUIFont", weight: .regular))
        #expect(provider.resolveRuns(text: "ab粗体").last?.font.id == regular.id)
        #expect(provider.resolveRuns(text: "ab粗体").map(\.text).joined() == "ab粗体")
    }

    @Test("Bold Latin text falls back to a heavier CJK face of the same family, regular to a regular one")
    func boldFallback() throws {
        let regular = try #require(fallbackName(weight: .regular))
        let bold = try #require(fallbackName(weight: .bold))
        #expect(regular != bold, "regular \(regular), bold \(bold)")
        #expect(weight(of: regular) <= 0.05, "regular fell back to \(regular)")
        #expect(weight(of: bold) > weight(of: regular), "regular \(regular), bold \(bold)")
        // Weight changes, the family does not.
        #expect(regular.split(separator: "-").first == bold.split(separator: "-").first, "regular \(regular), bold \(bold)")
    }
}
#endif
