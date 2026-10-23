import EditorCore
@testable import EditorUI
import GuavaUICompose
import Testing

private func apply(_ format: MarkdownFormat, to text: String, _ selection: Range<Int>) -> (String, Int) {
    let buffer = TextBuffer(text)
    let edit = format.edit(in: buffer, selection: selection)
    return (buffer.replace(characterRange: edit.range, with: edit.replacement).stringValue, edit.caret)
}

@Test func inlineFormatsWrapAndUnwrapTheSelection() {
    #expect(apply(.bold, to: "make it bold", 8..<12) == ("make it **bold**", 14))
    // Selecting the inner text of an already-bold span removes the markers.
    #expect(apply(.bold, to: "make it **bold**", 10..<14).0 == "make it bold")
    #expect(apply(.bold, to: "**bold**", 0..<8).0 == "bold")
    #expect(apply(.italic, to: "", 0..<0) == ("_italic text_", 12))
    #expect(apply(.link, to: "see docs", 4..<8) == ("see [docs](https://)", 19))
}

@Test func lineFormatsToggleEveryTouchedLine() {
    #expect(apply(.bulletList, to: "one\ntwo", 0..<7).0 == "- one\n- two")
    #expect(apply(.bulletList, to: "- one\n- two", 0..<11).0 == "one\ntwo")
    #expect(apply(.bulletList, to: "", 0..<0).0 == "- ")
    #expect(apply(.numberedList, to: "a\nb\nc", 2..<5).0 == "a\n1. b\n2. c")
    #expect(apply(.quote, to: "text\r\nmore", 0..<10).0 == "> text\r\n> more")
    // Headings cycle # → ## → ### → plain text.
    #expect(apply(.heading, to: "Title", 2..<2).0 == "# Title")
    #expect(apply(.heading, to: "# Title", 2..<2).0 == "## Title")
    #expect(apply(.heading, to: "### Title", 2..<2).0 == "Title")
}

@Test func statisticsCountWordsIncludingCJK() {
    let stats = DocumentStatistics("Hello, world!\n\n你好世界 again\n")
    #expect(stats.words == 2 + 4 + 1)
    #expect(stats.characters == 13 - 1 + 4 + 5)
    #expect(stats.paragraphs == 2)
    #expect(stats.readingMinutes == 1)
    #expect(DocumentStatistics("").readingMinutes == 0)
}

@Test func headingsSkipCodeFencesAndNonHeadings() {
    let text = "# Title\nintro\n```\n# not a heading\n```\n## Part ##\n#hashtag\n    # indented code\n### Detail"
    let headings = DocumentHeading.parse(text)
    #expect(headings.map(\.title) == ["Title", "Part", "Detail"])
    #expect(headings.map(\.level) == [1, 2, 3])
    #expect(headings[1].characterIndex == text.distance(from: text.startIndex, to: text.range(of: "## Part")!.lowerBound))
}

@Test func declarativeOutlineRulesUseCapturedTitles() {
    let rules = [
        LanguageOutlineRule(pattern: #"\\chapter\*?\{([^}]*)\}"#, level: 1),
        LanguageOutlineRule(pattern: #"\\section\*?\{([^}]*)\}"#, level: 2),
    ]
    let text = "\\chapter{Intro}\n\\section*{Part}\n% \\section{Hidden}\n\\section{}"
    let headings = DocumentHeading.parse(text, rules: rules)
    #expect(headings.map(\.title) == ["Intro", "Part", "Hidden"])
    #expect(headings.map(\.level) == [1, 2, 2])
    #expect(headings[0].characterIndex == 0)
    #expect(headings[1].characterIndex == text.distance(from: text.startIndex,
                                                       to: text.range(of: "\\section*")!.lowerBound))
    #expect(DocumentHeading.parse("# Markdown", rules: rules) == [])
}
