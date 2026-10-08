import Testing
@testable import GuavaUICompose

@Suite("Incremental visual line index")
struct TextVisualLineIndexTests {
    @Test("Wrapping and splicing preserve bidirectional positions and old snapshots")
    func randomChanges() {
        var index = TextVisualLineIndex(lineCount: 1_000)
        var expected = Array(repeating: 1, count: 1_000)
        var seed: UInt64 = 321
        func random(_ maximum: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            return Int(seed >> 32) % maximum
        }
        for iteration in 0..<2_000 {
            let old = index, oldTotal = expected.reduce(0, +)
            let line = random(expected.count)
            if iteration % 3 == 0 {
                let end = min(expected.count, line + random(8) + 1), count = random(8) + 1
                index.replace(lines: line..<end, withLineCount: count)
                expected.replaceSubrange(line..<end, with: repeatElement(1, count: count))
            } else {
                let count = random(20) + 1
                index.measure(line: line, rows: count); expected[line] = count
            }
            #expect(old.rowCount == oldTotal)
            #expect(index.lineCount == expected.count)
            #expect(index.rowCount == expected.reduce(0, +))
            #expect(index.height < 32)
            if iteration % 50 == 0 {
                var row = 0
                for (line, count) in expected.enumerated() {
                    #expect(index.firstRow(ofLine: line) == row)
                    for offset in [0, count - 1] {
                        let location = index.location(atRow: row + offset)
                        #expect(location.line == line && location.subrow == offset)
                    }
                    row += count
                }
            }
        }
    }
    @Test("Two hundred thousand unwrapped lines remain one run")
    func largeUnwrappedDocument() {
        var index = TextVisualLineIndex(lineCount: 200_000)
        for _ in 0..<1_000 { index.replace(lines: 100_000..<100_001, withLineCount: 1) }
        #expect(index.height == 1)
        #expect(index.firstRow(ofLine: 150_000) == 150_000)
        #expect(index.location(atRow: 150_000).line == 150_000)
    }
}
