import Foundation
// swift-markdown (cmark-gfm) stays an implementation detail: its AST is
// converted here and never crosses this file.
private import Markdown

enum MarkdownParser {
    private static let cache = MarkdownParseCache()

    /// CommonMark with the GFM tables, strikethrough and task-list extensions.
    static func blocks(_ source: String) -> [MarkdownBlock] {
        cache.value(for: source) { blocks(in: Markdown.Document(parsing: source)) }
    }

    private static func blocks(in parent: any Markup) -> [MarkdownBlock] {
        parent.children.compactMap(block)
    }

    private static func block(_ markup: any Markup) -> MarkdownBlock? {
        switch markup {
        case let heading as Markdown.Heading:
            return .heading(level: heading.level, runs(in: heading))
        case let paragraph as Markdown.Paragraph:
            return .paragraph(runs(in: paragraph))
        case let quote as Markdown.BlockQuote:
            return .quote(blocks(in: quote))
        case let list as Markdown.UnorderedList:
            return .list(MarkdownList(start: nil, items: list.listItems.map(item)))
        case let list as Markdown.OrderedList:
            return .list(MarkdownList(start: Int(list.startIndex), items: list.listItems.map(item)))
        case let code as Markdown.CodeBlock:
            let text = code.code.hasSuffix("\n") ? String(code.code.dropLast()) : code.code
            return .code(language: code.language.flatMap { $0.isEmpty ? nil : $0 }, text: text)
        case let html as Markdown.HTMLBlock:
            let text = html.rawHTML.trimmingCharacters(in: .newlines)
            return text.isEmpty ? nil : .code(language: "html", text: text)
        case is Markdown.ThematicBreak:
            return .rule
        case let table as Markdown.Table:
            return .table(MarkdownTable(
                alignments: table.columnAlignments.map {
                    switch $0 {
                    case .center: .center
                    case .right: .trailing
                    case .left, nil: .leading
                    }
                },
                header: table.head.cells.map { runs(in: $0) },
                rows: table.body.rows.map { row in row.cells.map { runs(in: $0) } }))
        default:
            let text = markup.format().trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : .paragraph([RichTextRun(text)])
        }
    }

    private static func item(_ item: Markdown.ListItem) -> MarkdownList.Item {
        let checked: Bool? = switch item.checkbox {
        case .checked: true
        case .unchecked: false
        case nil: nil
        }
        return MarkdownList.Item(isChecked: checked, blocks: blocks(in: item))
    }

    // MARK: - Inline

    private static func runs(in parent: any Markup) -> [RichTextRun] {
        var result: [RichTextRun] = []
        appendRuns(of: parent, traits: [], link: nil, into: &result)
        return merged(result)
    }

    private static func appendRuns(of parent: any Markup, traits: RichTextTraits, link: String?,
                                   into result: inout [RichTextRun]) {
        for child in parent.children {
            switch child {
            case let text as Markdown.Text:
                result.append(RichTextRun(text.string, traits: traits, link: link))
            case let code as Markdown.InlineCode:
                result.append(RichTextRun(code.code, traits: traits.union(.code), link: link))
            case is Markdown.SoftBreak:
                result.append(RichTextRun(" ", traits: traits, link: link))
            case is Markdown.LineBreak:
                result.append(RichTextRun("\n", traits: traits, link: link))
            case let emphasis as Markdown.Emphasis:
                appendRuns(of: emphasis, traits: traits.union(.italic), link: link, into: &result)
            case let strong as Markdown.Strong:
                appendRuns(of: strong, traits: traits.union(.bold), link: link, into: &result)
            case let strike as Markdown.Strikethrough:
                appendRuns(of: strike, traits: traits.union(.strikethrough), link: link, into: &result)
            case let anchor as Markdown.Link:
                let destination = anchor.destination ?? link
                if anchor.childCount == 0, let destination {
                    result.append(RichTextRun(destination, traits: traits, link: destination))
                } else {
                    appendRuns(of: anchor, traits: traits, link: destination, into: &result)
                }
            case let image as Markdown.Image:
                // Images render as their alternative text, linked to the source.
                let alt = image.plainText.isEmpty ? (image.source ?? "image") : image.plainText
                result.append(RichTextRun(alt, traits: traits.union(.italic), link: image.source ?? link))
            case let html as Markdown.InlineHTML:
                result.append(RichTextRun(html.rawHTML, traits: traits.union(.code), link: link))
            case let symbol as Markdown.SymbolLink:
                result.append(RichTextRun(symbol.destination ?? "", traits: traits.union(.code), link: link))
            default:
                appendRuns(of: child, traits: traits, link: link, into: &result)
            }
        }
    }

    /// Adjacent runs with the same style become one, so text shapes in fewer pieces.
    private static func merged(_ runs: [RichTextRun]) -> [RichTextRun] {
        var result: [RichTextRun] = []
        for run in runs where !run.text.isEmpty {
            if let last = result.last, last.traits == run.traits, last.link == run.link {
                result[result.count - 1].text += run.text
            } else {
                result.append(run)
            }
        }
        return result
    }
}

/// Parsed documents keyed by source; recomposition re-reads the same text.
private final class MarkdownParseCache: @unchecked Sendable {
    private let lock = NSLock()
    private var table: [String: [MarkdownBlock]] = [:]

    func value(for source: String, parse: () -> [MarkdownBlock]) -> [MarkdownBlock] {
        if let hit = lock.withLock({ table[source] }) { return hit }
        let blocks = parse()
        lock.withLock {
            if table.count >= 64 { table.removeAll(keepingCapacity: true) }
            table[source] = blocks
        }
        return blocks
    }
}
