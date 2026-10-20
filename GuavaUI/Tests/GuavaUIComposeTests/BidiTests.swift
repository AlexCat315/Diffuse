import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Bidirectional paragraphs", .serialized)
struct BidiTests: GuavaUIComposeSerializedSuite {
    @Test("Classes cover strong, number, separator and mark types")
    func classes() {
        #expect(BidiClass("a") == .l)
        #expect(BidiClass("ש") == .r)
        #expect(BidiClass("م") == .al)
        #expect(BidiClass("1") == .en)
        #expect(BidiClass("\u{0661}") == .an)
        #expect(BidiClass("+") == .es)
        #expect(BidiClass("%") == .et)
        #expect(BidiClass(",") == .cs)
        #expect(BidiClass(" ") == .ws)
        #expect(BidiClass("\n") == .b)
        #expect(BidiClass("\u{05B4}") == .nsm)
        #expect(BidiClass("!") == .on)
        #expect(BidiClass("\u{200F}") == .r)
        #expect(BidiClass("中") == .l)
    }

    @Test("Levels follow the paragraph direction, numbers and neutrals")
    func levels() {
        let ltr = BidiParagraphs("abc שלום def")
        #expect(ltr.paragraphs.first?.baseLevel == 0)
        let hebrewStart = "abc ".utf8.count
        #expect(ltr.level(atByte: 0) == 0)
        #expect(ltr.level(atByte: hebrewStart) == 1)
        #expect(ltr.level(atByte: hebrewStart - 1) == 0) // space between L and R takes the embedding level
        let rtl = BidiParagraphs("שלום 123 world!")
        #expect(rtl.paragraphs.first?.isRightToLeft == true)
        let digits = "שלום ".utf8.count
        #expect(rtl.level(atByte: digits) == 2)
        #expect(rtl.level(atByte: "שלום 123 ".utf8.count) == 2)
        // Trailing neutral at the paragraph end resolves to the embedding direction.
        #expect(rtl.level(atByte: rtl.levels.count - 1) == 1)
        let arabic = BidiParagraphs("عدد 12")
        #expect(arabic.level(atByte: "عدد ".utf8.count) == 2) // W2: EN after AL becomes AN, still level 2
        #expect(!BidiParagraphs.containsRightToLeft("plain text 123"))
        #expect(BidiParagraphs.containsRightToLeft("x\u{0627}"))
    }

    @Test("Each hard line break starts a paragraph with its own base direction")
    func paragraphs() {
        let text = "Hello\nשלום"
        let bidi = BidiParagraphs(text)
        #expect(bidi.paragraphs.count == 2)
        #expect(bidi.paragraphs[0].baseLevel == 0)
        #expect(bidi.paragraphs[1].baseLevel == 1)
        #expect(bidi.paragraph(atByte: text.utf8.count - 1).isRightToLeft)
        #expect(BidiParagraphs("123", defaultRightToLeft: true).paragraphs.first?.baseLevel == 1)
    }

    @Test("L2 reverses runs from the highest level down")
    func visualOrder() {
        #expect(BidiParagraphs.visualOrder([0, 0, 1, 1, 0]) == [0, 1, 3, 2, 4])
        #expect(BidiParagraphs.visualOrder([1, 1, 2, 2, 1]) == [4, 2, 3, 1, 0])
        #expect(BidiParagraphs.visualOrder([0, 0]) == [0, 1])
    }

    @Test("Text layout orders runs visually and right-aligns right-to-left paragraphs")
    func layoutOrder() {
        GlobalTestLock.locked {
            let env = TestTextEnvironmentFactory.make()
            let text = "abc שלום"
            let layout = env.cachedLayout(text: text, maxWidth: 400)
            let glyphs = layout.lines[0].glyphs
            let latin = glyphs.filter { $0.cluster < 3 }.map(\.x)
            let hebrew = glyphs.filter { $0.cluster >= 4 }
            #expect(latin == latin.sorted())
            // Hebrew letters are drawn right to left: later characters sit further left.
            let byCluster = hebrew.sorted { $0.cluster < $1.cluster }.map(\.x)
            if byCluster.count > 1 { #expect(byCluster == byCluster.sorted(by: >)) }

            let rtl = env.cachedLayout(text: "שלום", maxWidth: 400)
            let line = rtl.lines[0]
            if let first = line.glyphs.map(\.x).min() { #expect(first >= 400 - line.width - 0.5) }
            let ltr = env.cachedLayout(text: "abc", maxWidth: 400)
            #expect((ltr.lines[0].glyphs.map(\.x).min() ?? 0) < 1)
        }
    }

    @Test("Rich text aligns each paragraph line by its own direction")
    func richTextAlignment() {
        GlobalTestLock.locked {
            let env = TestTextEnvironmentFactory.make()
            let paragraph = RichParagraph(spans: [.init(text: "English\nעברית", font: env.defaultFont, lineHeight: 20, traits: [], link: nil)])
            let flow = RichTextFlow.layout(paragraph, maxWidth: 300, env: env)
            #expect(flow.lines.count == 2)
            #expect(flow.lines[0].isRightToLeft == false)
            #expect(flow.lines[1].isRightToLeft == true)
            let second = flow.glyphs.lines[1].glyphs.map(\.x)
            #expect((second.min() ?? 0) > 300 - flow.lines[1].width - 1)
        }
    }
}
