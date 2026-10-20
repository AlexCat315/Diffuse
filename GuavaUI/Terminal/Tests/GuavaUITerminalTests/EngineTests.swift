import Testing
@testable import GuavaUITerminal

@Suite("libghostty-vt engine")
struct EngineTests {
    private func engine(_ columns: Int = 20, _ rows: Int = 4, scrollback: Int = 100) -> TerminalEngine {
        TerminalEngine(columns: columns, rows: rows, scrollbackLines: scrollback)
    }

    @Test("Plain text, line breaks and cursor")
    func plainText() {
        let engine = engine()
        engine.feed(Array("Hello\r\nWorld\r\n".utf8))
        let frame = engine.snapshot()
        #expect(frame.columns == 20 && frame.rows == 4)
        #expect(frame.text(ofRow: 0) == "Hello")
        #expect(frame.text(ofRow: 1) == "World")
        #expect(frame.text(ofRow: 2) == "")
        #expect(frame.cursor.isVisible)
        #expect(frame.cursor.column == 0 && frame.cursor.row == 2)
    }

    @Test("SGR attributes and palette colors resolve per cell")
    func styles() {
        let engine = engine()
        engine.feed(Array("\u{1B}[1;32mOK\u{1B}[0m \u{1B}[4;9mx\u{1B}[0m \u{1B}[7mi\u{1B}[0m".utf8))
        let frame = engine.snapshot()
        #expect(frame.text(ofRow: 0) == "OK x i")
        #expect(frame[0, 0].attributes == [.bold])
        #expect(frame[0, 0].foreground != nil)
        #expect(frame[0, 2].foreground == nil && frame[0, 2].attributes.isEmpty)
        #expect(frame[0, 3].attributes == [.underline, .strikethrough])
        #expect(frame[0, 5].attributes == [.inverse])
    }

    @Test("Truecolor foreground and background")
    func truecolor() {
        let engine = engine()
        engine.feed(Array("\u{1B}[38;2;10;20;30;48;2;200;100;50mZ".utf8))
        let cell = engine.snapshot()[0, 0]
        #expect(cell.foreground == TerminalRGB(r: 10, g: 20, b: 30))
        #expect(cell.background == TerminalRGB(r: 200, g: 100, b: 50))
    }

    @Test("Wide characters take a cell plus a spacer")
    func wideCharacters() {
        let engine = engine()
        engine.feed(Array("你好a".utf8))
        let frame = engine.snapshot()
        #expect(frame[0, 0].text == "你" && frame[0, 0].width == .wide)
        #expect(frame[0, 1].width == .spacer)
        #expect(frame[0, 2].text == "好" && frame[0, 2].width == .wide)
        #expect(frame[0, 4].text == "a" && frame[0, 4].width == .narrow)
        #expect(frame.cursor.column == 5)
        #expect(frame.text(ofRow: 0) == "你好a")
    }

    @Test("Combining marks stay in one grapheme cell")
    func graphemes() {
        let engine = engine()
        engine.feed(Array("e\u{301}x".utf8))
        let frame = engine.snapshot()
        #expect(frame[0, 0].text == "e\u{301}")
        #expect(frame[0, 1].text == "x")
    }

    @Test("Resize reflows soft-wrapped lines")
    func resize() {
        let engine = engine(10, 3)
        engine.feed(Array("ABCDEFGHIJKLMNOP".utf8))
        var frame = engine.snapshot()
        #expect(frame.text(ofRow: 0) == "ABCDEFGHIJ")
        #expect(frame.text(ofRow: 1) == "KLMNOP")
        engine.resize(columns: 8, rows: 4, cellWidth: 8, cellHeight: 16)
        frame = engine.snapshot()
        #expect(frame.columns == 8 && frame.rows == 4)
        #expect(frame.text(ofRow: 0) == "ABCDEFGH")
        #expect(frame.text(ofRow: 1) == "IJKLMNOP")
    }

    @Test("Viewport scrolls through history and back")
    func scrollback() {
        let engine = engine(10, 3)
        engine.feed(Array((1...10).map { "line\($0)" }.joined(separator: "\r\n").utf8))
        var frame = engine.snapshot()
        #expect(frame.text(ofRow: 2) == "line10")
        #expect(frame.scroll.isAtBottom)
        engine.scroll(rows: -2)
        frame = engine.snapshot()
        #expect(frame.text(ofRow: 0) == "line6")
        #expect(!frame.scroll.isAtBottom)
        #expect(!frame.cursor.isVisible)
        engine.scrollToBottom()
        #expect(engine.snapshot().text(ofRow: 0) == "line8")
    }

    @Test("Queries are answered through the reply callback")
    func replies() {
        let engine = engine()
        var replies: [[UInt8]] = []
        engine.onReply = { replies.append($0) }
        engine.feed(Array("ab\u{1B}[6n".utf8))
        #expect(replies.map { String(decoding: $0, as: UTF8.self) } == ["\u{1B}[1;3R"])
    }

    @Test("Title changes and bell are reported")
    func titleAndBell() {
        let engine = engine()
        var titles: [String] = []
        var bells = 0
        engine.onTitleChange = { titles.append($0) }
        engine.onBell = { bells += 1 }
        engine.feed(Array("\u{1B}]0;build — zsh\u{07}\u{07}".utf8))
        #expect(titles == ["build — zsh"])
        #expect(engine.title == "build — zsh")
        #expect(bells == 1)
    }

    @Test("Paste follows bracketed-paste mode")
    func paste() {
        let engine = engine()
        #expect(engine.encodePaste("a\nb") == Array("a\rb".utf8))
        engine.feed(Array("\u{1B}[?2004h".utf8))
        #expect(engine.encodePaste("a\nb") == Array("\u{1B}[200~a\nb\u{1B}[201~".utf8))
        #expect(engine.encodePaste("") == [])
    }

    @Test("Key encoding follows the program's keyboard modes")
    func keys() {
        let engine = engine()
        let up = TerminalKey(scancode: 82)
        #expect(engine.encode(up) == Array("\u{1B}[A".utf8))
        engine.feed(Array("\u{1B}[?1h".utf8)) // DECCKM: application cursor keys
        #expect(engine.encode(up) == Array("\u{1B}OA".utf8))
        #expect(engine.encode(TerminalKey(scancode: 40)) == [0x0D])
        #expect(engine.encode(TerminalKey(scancode: 42)) == [0x7F])
        #expect(engine.encode(TerminalKey(scancode: 6, modifiers: .control, text: "c")) == [0x03])
        #expect(engine.encode(TerminalKey(scancode: 43, modifiers: .shift)) == Array("\u{1B}[Z".utf8))
        #expect(engine.encode(TerminalKey(scancode: 0xFFFF)) == [])
    }

    @Test("Alternate screen is tracked")
    func alternateScreen() {
        let engine = engine()
        #expect(!engine.isAlternateScreen)
        engine.feed(Array("\u{1B}[?1049h".utf8))
        #expect(engine.isAlternateScreen)
        engine.feed(Array("\u{1B}[?1049l".utf8))
        #expect(!engine.isAlternateScreen)
    }
}
