import Foundation
import Testing
@testable import GuavaUICompose

@Suite("Persistent Rope text buffer")
struct TextBufferTests {
    @Test("Content equality is separate from revision identity and skips shared text after reversion")
    func contentEquality() {
        let original = TextBuffer(String(repeating: "let value = 123\n", count: 100_000))
        let middle = original.lineRange(forLine: 50_000).upperBound
        let changed = original.insert("x", atCharacterIndex: middle)
        let restored = changed.delete(characterRange: middle..<(middle + 1))
        #expect(restored != original && restored.hasSameContents(as: original))
        #expect(!changed.hasSameContents(as: original))
        #expect(TextBuffer("a😀\r\nb").hasSameContents(as: TextBuffer("a😀\r\nb")))
        #expect(!TextBuffer("é").hasSameContents(as: TextBuffer("e\u{301}")))
        #expect(TextBuffer.empty.hasSameContents(as: TextBuffer("")))
    }
    @Test("Leaves preserve UTF-8 and extended grapheme clusters at the chunk boundary")
    func chunkBoundaries() {
        for tail in ["界", "😀", "👩🏽‍💻", "á", "🇨🇳"] {
            let source = String(repeating: "a", count: 1023) + tail + "end"
            let buffer = TextBuffer(source)
            #expect(buffer.stringValue == source)
            #expect(buffer.characterCount == source.count)
            #expect(buffer.substring(characterRange: 1023..<1024) == tail)
        }
    }

    @Test("Line lookup spans leaves and excludes LF, CRLF and CR separators")
    func lineBoundaries() {
        let first = String(repeating: "x", count: 3000)
        let buffer = TextBuffer(first + "\r\n中文\n\rfinal\n")
        #expect(buffer.lineCount == 5)
        #expect(buffer.lineRange(forLine: 0) == 0..<3000)
        #expect(buffer.lineRange(forLine: 1) == 3001..<3003)
        #expect(buffer.lineRange(forLine: 2) == 3004..<3004)
        #expect(buffer.lineRange(forLine: 3) == 3005..<3010)
        #expect(buffer.lineRange(forLine: 4) == 3011..<3011)
        #expect(buffer.lineIndex(forCharacterIndex: 3001) == 1)
    }

    private struct Random {
        var value: UInt64 = 0xCAFE_0123_ABCD
        mutating func next(_ limit: Int) -> Int {
            value = value &* 6364136223846793005 &+ 1442695040888963407
            return Int(value >> 32) % max(1, limit)
        }
    }
    private func replay(_ delta: TextEditDelta, on previous: TextBuffer) -> String {
        var bytes = previous.utf8Bytes(inUTF8Range: 0..<previous.utf8Length)
        bytes.replaceSubrange(delta.startUTF8Offset..<delta.oldEndUTF8Offset, with: delta.newText.utf8)
        return String(decoding: bytes, as: UTF8.self)
    }
    private func assertIndexes(_ buffer: TextBuffer, source: String) {
        var byte = 0, utf16 = 0, index = 0
        for character in source {
            #expect(buffer.utf8Offset(forCharacterIndex: index) == byte)
            #expect(buffer.utf16Offset(forCharacterIndex: index) == utf16)
            #expect(buffer.characterIndex(forUTF8Offset: byte) == index)
            for offset in (byte + 1)..<(byte + character.utf8.count) {
                #expect(buffer.characterIndex(forUTF8Offset: offset) == index + 1)
            }
            byte += character.utf8.count; utf16 += character.utf16.count; index += 1
        }
        #expect(buffer.utf8Offset(forCharacterIndex: index) == byte && byte == buffer.utf8Length)
        #expect(buffer.characterIndex(forUTF8Offset: byte) == index && index == buffer.characterCount)
        #expect(buffer.utf16Length == utf16)
        var ranges: [Range<Int>] = [], start = 0
        for (index, character) in source.enumerated() where character.isNewline {
            ranges.append(start..<index); start = index + 1
        }
        ranges.append(start..<source.count)
        #expect(buffer.lineCount == ranges.count)
        for (line, range) in ranges.enumerated() {
            #expect(buffer.lineRange(forLine: line) == range)
            #expect(buffer.characterIndex(forLine: line, character: Int.max) == range.upperBound)
            #expect(buffer.lineIndex(forCharacterIndex: range.lowerBound) == line)
        }
    }
    private func assertBalanced(_ node: RopeNode) {
        switch node.storage {
        case .leaf(let leaf):
            #expect(String(bytes: leaf.bytes, encoding: .utf8) != nil)
            #expect(leaf.bytes.count <= RopeNode.maxLeafBytes || leaf.text.count == 1)
        case .branch(let branch):
            #expect(abs(branch.left.metrics.height - branch.right.metrics.height) <= 1)
            assertBalanced(branch.left); assertBalanced(branch.right)
        }
    }

    @Test("Deterministic Unicode edits match String, including grapheme-merging seams and recorded deltas")
    func randomizedEdits() {
        var source = String(repeating: "ab中文😀\r\n", count: 300), buffer = TextBuffer(source), random = Random()
        let tokens = ["", "x", "界", "á", "👩🏽‍💻", "\u{301}", "\u{200D}", "🇨", "🇳", "\r", "\n", "\r\n", "क्", "ष"]
        for edit in 0..<1500 {
            let old = buffer, oldSource = source
            let start = random.next(source.count + 1), length = random.next(min(8, source.count - start) + 1)
            let insertion = tokens[random.next(tokens.count)]
            let lower = source.index(source.startIndex, offsetBy: start), upper = source.index(lower, offsetBy: length)
            source.replaceSubrange(lower..<upper, with: insertion)
            buffer = buffer.replace(characterRange: start..<(start + length), with: insertion)
            #expect(buffer.stringValue == source && buffer.characterCount == source.count)
            #expect(old.stringValue == oldSource)
            if let delta = buffer.editDelta(from: old) { #expect(replay(delta, on: old) == source) }
            else { #expect(source == oldSource) }
            if edit % 50 == 0 { assertIndexes(buffer, source: source); assertBalanced(buffer.root) }
        }
        assertIndexes(buffer, source: source); assertBalanced(buffer.root)
    }

    @Test("Regional indicators re-pair across leaves; oversized combining graphemes remain intact")
    func dependentUnicodeBoundaries() {
        let source = String(repeating: "🇨🇳", count: 800) + "end"
        let buffer = TextBuffer(source).insert("🇺", atCharacterIndex: 0)
        #expect(buffer.stringValue == "🇺" + source && buffer.characterCount == ("🇺" + source).count)
        assertIndexes(buffer, source: "🇺" + source); assertBalanced(buffer.root)
        let large = "a" + String(repeating: "\u{301}", count: 2000)
        let combined = TextBuffer(large + "b").insert("\u{301}", atCharacterIndex: 1)
        #expect(combined.characterCount == 2)
        #expect(combined.substring(characterRange: 0..<1) == large + "\u{301}")
        assertBalanced(combined.root)
        let crlf = TextBuffer("x\ny").insert("\r", atCharacterIndex: 1)
        #expect(crlf.lineCount == 2 && crlf.characterCount == 3 && crlf.lineRange(forLine: 1) == 2..<3)
    }

    @Test("Deltas across several revisions, undo and independent loads replay exactly")
    func deltaAcrossRevisions() {
        let original = TextBuffer(String(repeating: "let café = \"😀\"\n", count: 1000))
        let edited = original.insert("new", atCharacterIndex: 8000).delete(characterRange: 20..<30).insert("\u{301}", atCharacterIndex: 100)
        #expect(replay(edited.editDelta(from: original)!, on: original) == edited.stringValue)
        #expect(replay(original.editDelta(from: edited)!, on: edited) == original.stringValue)
        #expect(TextBuffer(original.stringValue).editDelta(from: original) == nil)
        let replacement = TextBuffer("completely different\n内容")
        #expect(replay(replacement.editDelta(from: original)!, on: original) == replacement.stringValue)
        let before = TextBuffer("a"), after = before.insert("\u{301}", atCharacterIndex: 1).insert("b", atCharacterIndex: 1)
        #expect(replay(after.editDelta(from: before)!, on: before) == "áb")
    }

    @Test("Parser LF points and LSP UTF-16 indexes do not confuse scalar, grapheme or CRLF boundaries")
    func protocolCoordinates() {
        let buffer = TextBuffer("á😀\r\n界\rtext")
        #expect(buffer.utf8Offset(forUTF16Offset: 1) == 1)
        #expect(buffer.utf8Offset(forUTF16Offset: 2) == 3)
        #expect(buffer.utf8Offset(forUTF16Offset: 3) == 7)
        #expect(buffer.utf16Offset(forUTF8Offset: 3) == 2)
        #expect(buffer.utf16Offset(forUTF8Offset: 7) == 4)
        #expect(buffer.parserPoint(forUTF8Offset: 8) == TextBufferPoint(row: 0, columnUTF8: 8))
        #expect(buffer.point(forUTF8Offset: 8) == TextBufferPoint(row: 0, columnUTF8: 8))
        #expect(buffer.parserPoint(forUTF8Offset: 9) == TextBufferPoint(row: 1, columnUTF8: 0))
        #expect(buffer.parserPoint(forUTF8Offset: 13) == TextBufferPoint(row: 1, columnUTF8: 4))
        #expect(buffer.point(forUTF8Offset: 13) == TextBufferPoint(row: 2, columnUTF8: 0))
    }

    @Test("Unequal-height joins and repeated large replacement preserve balance and retained snapshots")
    func adversarialJoins() {
        let original = TextBuffer(String(repeating: "abcdefghijklmnopqrstuvwxyz\n", count: 4000))
        var buffer = original
        let block = String(repeating: "中文👩🏽‍💻\n", count: 1000)
        for step in 0..<100 {
            let start = step % 2 == 0 ? 0 : buffer.characterCount
            let enlarged = buffer.insert(block, atCharacterIndex: start)
            assertBalanced(enlarged.root)
            buffer = enlarged.delete(characterRange: start..<(start + block.count))
            #expect(buffer.characterCount == original.characterCount)
            assertBalanced(buffer.root)
        }
        #expect(buffer.stringValue == original.stringValue)
        #expect(buffer.editDelta(from: original) == nil)
    }

    @Test("A 100K-line document retains shared leaves and logarithmic depth through middle edits")
    func largeDocumentSharing() {
        let source = String(repeating: "let value = 12345\n", count: 100_000)
        let original = TextBuffer(source), leaves = original.visibleChunks(inUTF8Range: 0..<original.utf8Length)
        let ids = Set(leaves.map(ObjectIdentifier.init))
        var buffer = original
        let cursor = buffer.characterIndex(forLine: 50_000, character: 4)
        let clock = ContinuousClock(), start = clock.now
        for index in 0..<500 {
            buffer = buffer.insert("x", atCharacterIndex: cursor + index)
        }
        #expect(buffer.lineCount == 100_001 && buffer.characterCount == original.characterCount + 500)
        #expect(buffer.root.metrics.height < 32)
        let shared = buffer.visibleChunks(inUTF8Range: 0..<buffer.utf8Length).filter { ids.contains(ObjectIdentifier($0)) }
        #expect(shared.count >= leaves.count - 4)
        #expect(original.lineRange(forLine: 50_000).count == 17)
        #expect(buffer.visibleText(firstLine: 49_999, lastLine: 50_001).utf8.count < 600)
        #expect(buffer.chunk(atUTF8Offset: buffer.utf8Offset(forCharacterIndex: cursor))!.bytes.count <= 1024)
        assertBalanced(buffer.root)
        // Broad ceiling catches accidental whole-document rebuilding in debug builds.
        #expect(start.duration(to: clock.now) < .seconds(10))
    }
}
