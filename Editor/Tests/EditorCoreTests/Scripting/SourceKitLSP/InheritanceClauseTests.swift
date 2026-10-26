import CoveUICompose
import Testing
@testable import EditorCore

@Suite("Swift inheritance clause")
struct InheritanceClauseTests {
    private func names(_ source: String, line: Int = 0, character: Int) -> [String] {
        let text = TextBuffer(source)
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        return ScriptInheritanceClause.typePositions(in: text, declarationAt: .init(line: line, character: character)).map { position in
            String(lines[position.line].dropFirst(position.character).prefix { $0 == "_" || $0.isLetter || $0.isNumber })
        }
    }

    @Test("Inherited names resolve to their last component, across generics, compositions and lines")
    func positions() {
        #expect(names("struct GameScript: ScriptBehavior, ScriptAuthoring {", character: 7) == ["ScriptBehavior", "ScriptAuthoring"])
        #expect(names("final class Box<T: Equatable>: Base<T>, Runtime.Hashable & Sendable where T: Any {", character: 12)
                == ["Base", "Hashable", "Sendable"])
        #expect(names("enum Mode:\n    String,\n    CaseIterable\n{", character: 5) == ["String", "CaseIterable"])
        #expect(names("struct Plain {", character: 7).isEmpty)
        #expect(names("protocol Named { var name: String { get } }", character: 9).isEmpty)
    }
}
