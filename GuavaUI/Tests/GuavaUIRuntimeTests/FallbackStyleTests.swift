#if canImport(CoreText)
import Testing
@testable import GuavaUIRuntime

@Suite("Font fallback keeps the requested style")
struct FallbackStyleTests {
    private func fallbackName(weight: FontWeight, isItalic: Bool = false) -> String? {
        let provider = FontProvider(size: 14)
        _ = provider.loadPrimaryFont(name: ".AppleSystemUIFont", weight: weight, isItalic: isItalic)
        return provider.resolveRuns(text: "ab粗体").last?.font.postScriptName
    }

    @Test("Bold Latin text falls back to a heavier CJK face, regular to a regular one")
    func boldFallback() throws {
        let regular = try #require(fallbackName(weight: .regular))
        let bold = try #require(fallbackName(weight: .bold))
        #expect(regular != bold)
        #expect(!regular.contains("Bold") && !regular.contains("Semibold"))
        #expect(bold.contains("Bold") || bold.contains("Semibold") || bold.contains("Heavy"))
    }
}
#endif
