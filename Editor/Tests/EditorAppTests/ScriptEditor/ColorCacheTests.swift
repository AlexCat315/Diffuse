import Testing
@testable import EditorUI

@Suite("Swift syntax color cache")
struct ColorCacheTests {
    @Test("Repeated glyph and minimap queries reuse colored and plain decisions")
    func repeatedQueries() {
        let cache = ScriptSyntaxColorCache()
        var queries = 0
        for _ in 0..<100 {
            #expect(cache.kind(at: 3) { queries += 1; return .keyword } == .keyword)
            #expect(cache.kind(at: 7) { queries += 1; return nil } == nil)
        }
        #expect(queries == 2)
        cache.invalidate()
        #expect(cache.kind(at: 3) { queries += 1; return .stringLiteral } == .stringLiteral)
        #expect(cache.kind(at: 7) { queries += 1; return .comment } == .comment)
        #expect(queries == 4)
    }
}
