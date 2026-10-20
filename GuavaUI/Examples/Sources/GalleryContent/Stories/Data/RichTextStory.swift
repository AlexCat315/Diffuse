import GuavaUI

struct RichTextStory: View {
    @State private var lastOpened = "none"

    static let sample: [RichTextRun] = [
        RichTextRun("GuavaUI lays out "),
        RichTextRun("bold", traits: .bold),
        RichTextRun(", "),
        RichTextRun("italic", traits: .italic),
        RichTextRun(", "),
        RichTextRun("both at once", traits: [.bold, .italic]),
        RichTextRun(", "),
        RichTextRun("inline code", traits: .code),
        RichTextRun(" and "),
        RichTextRun("struck text", traits: .strikethrough),
        RichTextRun(" in one paragraph. Links such as the "),
        RichTextRun("layout guide", link: "guide://layout"),
        RichTextRun(" wrap with the words around them, even when a long link like "),
        RichTextRun("https://github.com/swiftlang/swift-markdown", link: "https://github.com/swiftlang/swift-markdown"),
        RichTextRun(" has to break across lines."),
    ]

    static let mixedScript: [RichTextRun] = [
        RichTextRun("中文段落按字断行，标点不会出现在行首。混排 "),
        RichTextRun("English words", traits: .bold),
        RichTextRun(" 时仍在空格处断开，"),
        RichTextRun("RichTextRun", traits: .code),
        RichTextRun(" 与"),
        RichTextRun("链接", link: "guide://cjk"),
        RichTextRun("也一起换行。"),
    ]

    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 24) {
            StorySection("Inline styles", "Runs share one flow: weight, slant, monospaced chips, strike lines and underlined links sit on a common baseline and wrap together.") {
                RichText(Self.sample) { lastOpened = $0 }
                Text("Last opened: \(lastOpened)").font(.caption).foregroundColor(.onSurfaceMuted)
            }
            StorySection("Mixed scripts", "Ideographs break between characters with the usual punctuation rules; Latin words still break at spaces.") {
                RichText(Self.mixedScript) { lastOpened = $0 }
            }
            StorySection("Type roles", "The paragraph takes the surrounding text style and foreground, scaled once by TextScaler.") {
                RichText([RichTextRun("A "), RichTextRun("headline", traits: .italic), RichTextRun(" paragraph")])
                    .font(.headline)
                RichText([RichTextRun("A muted caption with "), RichTextRun("code", traits: .code), RichTextRun(".")])
                    .font(.caption).foregroundColor(.onSurfaceMuted)
                RichText([RichTextRun("Centred text, with "), RichTextRun("emphasis", traits: .bold), RichTextRun(".")],
                         alignment: .center)
            }
        }
    }
}
