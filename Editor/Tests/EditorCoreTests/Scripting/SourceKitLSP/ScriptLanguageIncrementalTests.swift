import Foundation
import GuavaUICompose
import Testing
@testable import EditorCore

@Suite("Incremental LSP document synchronization")
struct ScriptLanguageIncrementalTests {
    private func replay(_ data: Data, on old: String) throws -> String {
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let changes = try #require(object["contentChanges"] as? [[String: Any]])
        #expect(changes.count == 1)
        let change = try #require(changes.first)
        let range = try #require(change["range"] as? [String: Any])
        func index(_ key: String) throws -> String.Index {
            let point = try #require(range[key] as? [String: Int])
            let row = try #require(point["line"]), column = try #require(point["character"])
            let lines = old.split(separator: "\n", omittingEmptySubsequences: false)
            let start = lines[row].startIndex
            return old.utf16.index(start, offsetBy: column)
        }
        var result = old
        result.replaceSubrange(try index("start")..<index("end"), with: try #require(change["text"] as? String))
        return result
    }
    @Test("UTF-16 ranges preserve emoji, combining scalars and CRLF")
    func unicodeWireRange() throws {
        let old: TextBuffer = "é😀e\u{301} tail\r\nlet 中文 = 2\r\n"
        let next = old.replace(characterRange: 3..<7, with: " replacement😀\n")
        let data = try #require(try ScriptLanguageQueries.didChange(uri: "file:///test.swift", previous: old, current: next, version: 2))
        #expect(try replay(data, on: old.stringValue) == next.stringValue)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let change = try #require((object["contentChanges"] as? [[String: Any]])?.first)
        let range = try #require(change["range"] as? [String: Any])
        #expect((range["start"] as? [String: Int])?["character"] == 5)
        #expect(ScriptSourceCoordinates.utf8Offset(in: old, at: .init(line: 0, character: 4)) == 7)
    }
    @Test("debounced edits and undo replay from the last sent snapshot")
    func coalescedAndUndo() throws {
        let old = TextBuffer(String(repeating: "let value = 1\n", count: 100_000))
        let index = old.lineRange(forLine: 50_000).upperBound
        var next = old
        for _ in 0..<40 { next = next.insert("x", atCharacterIndex: index) }
        let data = try #require(try ScriptLanguageQueries.didChange(uri: "file:///test.swift", previous: old, current: next, version: 2))
        #expect(data.count < 500)
        #expect(try replay(data, on: old.stringValue) == next.stringValue)
        let undo = try #require(try ScriptLanguageQueries.didChange(uri: "file:///test.swift", previous: next, current: old, version: 3))
        #expect(try replay(undo, on: next.stringValue) == old.stringValue)
        #expect(try ScriptLanguageQueries.didChange(uri: "file:///test.swift", previous: old, current: old, version: 4) == nil)
        #expect(try ScriptLanguageQueries.didChange(uri: "file:///test.swift", previous: old, current: TextBuffer(old.stringValue), version: 4) == nil)
    }
}
