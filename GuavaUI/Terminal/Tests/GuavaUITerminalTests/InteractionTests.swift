import Testing
@testable import GuavaUITerminal

@Suite("Selection, mouse reports, hyperlinks and images")
struct InteractionTests {
    private func engine(_ text: String = "") -> TerminalEngine {
        let engine = TerminalEngine(columns: 20, rows: 4, scrollbackLines: 100)
        engine.resize(columns: 20, rows: 4, cellWidth: 10, cellHeight: 20)
        engine.feed(Array(text.utf8))
        return engine
    }

    /// `inset` is the offset into the cell; selection includes a cell once the
    /// pointer passes its midpoint.
    private func pointer(_ column: Int, _ row: Int, at time: UInt64 = 0, inset: Double = 2) -> TerminalPointer {
        TerminalPointer(column: column, row: row, x: Double(column) * 10 + inset, y: Double(row * 20 + 8), nanoseconds: time)
    }

    @Test("Dragging selects text, which copies and renders as selected")
    func dragSelection() {
        let engine = engine("hello world\r\nsecond line")
        #expect(!engine.select(.press, at: pointer(0, 0, at: 1)))
        #expect(engine.select(.drag, at: pointer(4, 0)))
        #expect(engine.selectedText == "hell")
        #expect(engine.select(.drag, at: pointer(4, 0, inset: 7)))
        engine.select(.release, at: pointer(4, 0, inset: 7))
        #expect(engine.selectedText == "hello")
        let frame = engine.snapshot()
        #expect((0...4).allSatisfy { frame[0, $0].isSelected })
        #expect(!frame[0, 5].isSelected)
        #expect(engine.clearSelection())
        #expect(engine.selectedText == nil)
    }

    @Test("Double click selects a word, triple click a line, single click clears")
    func repeatClicks() {
        let engine = engine("hello world\r\nsecond line")
        let second: UInt64 = 1_000_000_000
        engine.select(.press, at: pointer(7, 0, at: second))
        engine.select(.release, at: pointer(7, 0))
        #expect(engine.select(.press, at: pointer(7, 0, at: second + 100_000_000)))
        engine.select(.release, at: pointer(7, 0))
        #expect(engine.selectedText == "world")
        #expect(engine.select(.press, at: pointer(7, 0, at: second + 200_000_000)))
        engine.select(.release, at: pointer(7, 0))
        #expect(engine.selectedText == "hello world")
        engine.select(.press, at: pointer(2, 1, at: second * 5))
        #expect(engine.selectedText == nil)
    }

    @Test("Mouse reports follow the program's tracking mode and format")
    func mouseReports() {
        let engine = engine()
        #expect(!engine.isMouseTracking)
        engine.feed(Array("\u{1B}[?1000h\u{1B}[?1006h".utf8))
        #expect(engine.isMouseTracking)
        let press = TerminalMouseEvent(action: .press, button: .left, x: 35, y: 45)
        #expect(String(decoding: engine.encode(press), as: UTF8.self) == "\u{1B}[<0;4;3M")
        let release = TerminalMouseEvent(action: .release, button: .left, x: 35, y: 45)
        #expect(String(decoding: engine.encode(release), as: UTF8.self) == "\u{1B}[<0;4;3m")
        let wheel = TerminalMouseEvent(action: .press, button: .wheelUp, x: 5, y: 5)
        #expect(String(decoding: engine.encode(wheel), as: UTF8.self) == "\u{1B}[<64;1;1M")
        // Normal tracking (1000) does not report motion without button-event mode.
        #expect(engine.encode(TerminalMouseEvent(action: .motion, button: nil, x: 50, y: 5)).isEmpty)
    }

    @Test("OSC 8 hyperlinks are flagged per cell and resolve to their URI")
    func hyperlinks() {
        let engine = engine("see \u{1B}]8;;https://example.com/a?b=1\u{1B}\\docs\u{1B}]8;;\u{1B}\\ now")
        let frame = engine.snapshot()
        #expect(frame.text(ofRow: 0) == "see docs now")
        #expect(!frame[0, 3].isHyperlink)
        #expect((4...7).allSatisfy { frame[0, $0].isHyperlink })
        #expect(engine.hyperlink(column: 5, row: 0) == "https://example.com/a?b=1")
        #expect(engine.hyperlink(column: 9, row: 0) == nil)
        #expect(engine.hyperlink(column: 99, row: 0) == nil)
    }

    @Test("Kitty raw RGBA images are placed at the cursor and readable as pixels")
    func kittyRGBA() {
        let engine = engine("ab")
        // 2×1 RGBA: red, then half-transparent blue.
        engine.feed(Array("\u{1B}_Ga=T,f=32,s=2,v=1,i=7,q=2;/wAA/wAA/4A=\u{1B}\\".utf8))
        let frame = engine.snapshot()
        let placement = try? #require(frame.images.first)
        #expect(frame.images.count == 1)
        #expect(placement?.imageID == 7)
        #expect(placement?.column == 2 && placement?.row == 0)
        #expect(placement?.imageSize.width == 2 && placement?.imageSize.height == 1)
        #expect(placement?.isBelowText == false)
        let pixels = engine.imagePixels(7)
        #expect(pixels?.pixels == [255, 0, 0, 255, 0, 0, 255, 128])
    }

    @Test("Kitty PNG images decode through the host image decoder")
    func kittyPNG() {
        let engine = engine()
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="
        engine.feed(Array("\u{1B}_Ga=T,f=100,i=3,q=2;\(png)\u{1B}\\".utf8))
        #expect(engine.snapshot().images.map(\.imageID) == [3])
        #expect(engine.imagePixels(3)?.width == 1)
        #expect(engine.imagePixels(3)?.pixels.count == 4)
    }
}
