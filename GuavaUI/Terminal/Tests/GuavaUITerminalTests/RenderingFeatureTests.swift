import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUITerminal

@Suite("Box drawing, URLs, placeholders, blink and block selection")
struct RenderingFeatureTests {
    private func engine(_ text: String = "", columns: Int = 40) -> TerminalEngine {
        let engine = TerminalEngine(columns: columns, rows: 4, scrollbackLines: 100)
        engine.resize(columns: columns, rows: 4, cellWidth: 10, cellHeight: 20)
        engine.feed(Array(text.utf8))
        return engine
    }

    @Test("Box-drawing arms follow the Unicode names")
    func boxArms() {
        typealias Arms = BoxDrawing.Arms
        #expect(BoxDrawing.arms(0x2500) == Arms(up: 0, right: 1, down: 0, left: 1))   // ─
        #expect(BoxDrawing.arms(0x253C) == Arms(up: 1, right: 1, down: 1, left: 1))   // ┼
        #expect(BoxDrawing.arms(0x2543) == Arms(up: 2, right: 1, down: 1, left: 2))   // ╃
        #expect(BoxDrawing.arms(0x2554) == Arms(up: 0, right: 3, down: 3, left: 0))   // ╔
        #expect(BoxDrawing.arms(0x256A) == Arms(up: 1, right: 3, down: 1, left: 3))   // ╪
        #expect(BoxDrawing.arms(0x257F) == Arms(up: 2, right: 0, down: 1, left: 0))   // ╿
        #expect(BoxDrawing.arms(0x2504) == nil)                                        // dashed: drawn separately
        #expect(BoxDrawing.handles(0x2588) && BoxDrawing.handles(0xE0B0) && !BoxDrawing.handles(0x41))
    }

    @Test("Lines reach every cell edge they name, so neighbours join")
    func boxGeometry() {
        let cell = UIRect(x: 0, y: 0, width: 10, height: 20)
        for scalar: UInt32 in [0x2500, 0x2502, 0x253C, 0x2550, 0x2551, 0x256C, 0x2588] {
            let list = DrawList()
            BoxDrawing.draw(scalar, in: cell, color: .white, into: list)
            let xs = list.vertices.map(\.posX), ys = list.vertices.map(\.posY)
            #expect(!xs.isEmpty, "U+\(String(scalar, radix: 16)) drew nothing")
            let arms = BoxDrawing.arms(scalar) ?? .init(up: 1, right: 1, down: 1, left: 1)
            if arms.left > 0 { #expect(xs.min()! <= 0) }
            if arms.right > 0 { #expect(xs.max()! >= 10) }
            if arms.up > 0 { #expect(ys.min()! <= 0) }
            if arms.down > 0 { #expect(ys.max()! >= 20) }
        }
    }

    @Test("Plain-text URLs are found with their columns and without trailing punctuation")
    func urls() {
        let engine = engine("see https://example.com/a_(b), www.guava.dev. x", columns: 60)
        let frame = engine.snapshot()
        let first = URLDetector.match(in: frame, row: 0, column: 10)
        #expect(first?.url.absoluteString == "https://example.com/a_(b)")
        #expect(first?.columns == 4...28)
        #expect(URLDetector.match(in: frame, row: 0, column: 29) == nil)
        #expect(URLDetector.match(in: frame, row: 0, column: 33)?.url.absoluteString == "https://www.guava.dev")
        #expect(URLDetector.match(in: frame, row: 0, column: 1) == nil)
    }

    @Test("Option-drag selects a rectangular block")
    func rectangleSelection() {
        let engine = engine("abcdef\r\nghijkl\r\nmnopqr")
        // Start left of the first cell's midpoint, end right of the last one's.
        func at(_ column: Int, _ row: Int, inset: Double) -> TerminalPointer {
            TerminalPointer(column: column, row: row, x: Double(column) * 10 + inset, y: Double(row) * 20 + 10, nanoseconds: 1)
        }
        engine.select(.press, at: at(1, 0, inset: 2))
        engine.select(.drag, at: at(3, 2, inset: 7), rectangle: true)
        #expect(engine.selectedText == "bcd\nhij\nnop")
        let frame = engine.snapshot()
        #expect(frame[1, 2].isSelected && !frame[1, 0].isSelected && !frame[1, 4].isSelected)
    }

    @Test("SGR 5 marks blinking text")
    func textBlink() {
        let frame = engine("\u{1B}[5mon\u{1B}[0m off").snapshot()
        #expect(frame[0, 0].attributes.contains(.blink))
        #expect(!frame[0, 3].attributes.contains(.blink))
    }

    @Test("Diacritic indices come from the Kitty table")
    func diacritics() {
        #expect(PlaceholderCell.index(0x0305) == 0)
        #expect(PlaceholderCell.index(0x030D) == 1)
        #expect(PlaceholderCell.index(0x1D244) == placeholderDiacritics.count - 1)
        #expect(PlaceholderCell.index(0x41) == nil)
    }

    @Test("Unicode placeholders draw their strip of a virtual placement")
    func placeholders() {
        let engine = engine()
        // 2×1 RGBA image 42 with a virtual placement two cells wide, one row high.
        engine.feed(Array("\u{1B}_Ga=T,U=1,i=42,c=2,r=1,f=32,s=2,v=1,q=2;/wAA/wAA/4A=\u{1B}\\".utf8))
        #expect(engine.snapshot().images.isEmpty)
        // Image id in the 256-colour foreground; first cell names row/column 0,
        // the second inherits the next column.
        engine.feed(Array("\u{1B}[38;5;42m\u{10EEEE}\u{0305}\u{0305}\u{10EEEE}\u{0305}\u{1B}[0m".utf8))
        let frame = engine.snapshot()
        #expect(frame.placeholders.count == 2)
        let placement = frame.images.first
        #expect(frame.images.count == 1)
        #expect(placement?.imageID == 42)
        #expect(placement?.column == 0 && placement?.row == 0)
        // A 2:1 image fitted into a 20×20 point box: full width, centred vertically.
        #expect(placement?.width == 20 && placement?.height == 10)
        #expect(placement?.offset.x == 0 && placement?.offset.y == 5)
        #expect(placement?.source.width == 2 && placement?.source.height == 1)
    }

    @Test("Placeholder runs split on image changes and explicit columns")
    func placeholderRuns() {
        func cell(_ column: Int, id: UInt32 = 1, imageColumn: UInt32? = nil) -> PlaceholderCell {
            var text = "\u{10EEEE}\u{0305}"
            if let imageColumn { text.unicodeScalars.append(Unicode.Scalar(placeholderDiacritics[Int(imageColumn)])!) }
            return PlaceholderCell(text: text, column: column, row: 0, foreground: id, underline: 0)!
        }
        let runs = PlaceholderRun.runs([cell(0, imageColumn: 0), cell(1), cell(2, imageColumn: 5), cell(3, id: 2)])
        #expect(runs.map(\.width) == [2, 1, 1])
        #expect(runs.map(\.imageColumn) == [0, 5, 0])
        #expect(runs.map(\.imageID) == [1, 1, 2])
    }
}
