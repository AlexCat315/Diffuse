/// The rendered subset of a Markdown document, independent of the parser.
indirect enum MarkdownBlock: Hashable {
    case paragraph([RichTextRun])
    case heading(level: Int, [RichTextRun])
    case quote([MarkdownBlock])
    case list(MarkdownList)
    case code(language: String?, text: String)
    case table(MarkdownTable)
    case rule
}

struct MarkdownList: Hashable {
    struct Item: Hashable {
        /// nil for a plain item; true/false for a GFM task item.
        var isChecked: Bool?
        var blocks: [MarkdownBlock]
    }

    /// nil for a bulleted list.
    var start: Int?
    var items: [Item]
}

struct MarkdownTable: Hashable {
    enum Alignment: Hashable { case leading, center, trailing }

    var alignments: [Alignment]
    var header: [[RichTextRun]]
    var rows: [[[RichTextRun]]]
}
