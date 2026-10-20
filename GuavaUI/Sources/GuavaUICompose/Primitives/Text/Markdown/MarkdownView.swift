import GuavaUIRuntime

/// Renders CommonMark with the GitHub extensions (tables, strikethrough,
/// task lists): headings, paragraphs with inline styles and links, quotes,
/// nested lists, code blocks that scroll sideways instead of wrapping,
/// tables and rules. It takes the surrounding text style and width and grows
/// to its content; place it in a `ScrollView` for long documents.
///
/// ```swift
/// MarkdownView(release.notes) { destination in router.open(destination) }
/// ```
///
/// Links are reported to `onOpenLink`; nothing is opened on the caller's
/// behalf. Images render as their linked alternative text.
public struct MarkdownView: View {
    private let source: String
    private let onOpenLink: ((String) -> Void)?

    public init(_ source: String, onOpenLink: ((String) -> Void)? = nil) {
        self.source = source
        self.onOpenLink = onOpenLink
    }

    public var body: some View {
        // One selection spans the document, so a drag can cross blocks.
        TextSelectionRoot {
            MarkdownBlocks(blocks: MarkdownParser.blocks(source), depth: 0, onOpenLink: onOpenLink)
        }
    }
}

/// A vertical run of blocks with document rhythm: headings get room above
/// them, everything else is evenly spaced.
struct MarkdownBlocks: View {
    let blocks: [MarkdownBlock]
    /// List nesting, which picks the bullet glyph.
    let depth: Int
    let onOpenLink: ((String) -> Void)?

    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 12) {
            for (index, block) in blocks.enumerated() {
                AnyView(MarkdownBlockView(block: block, depth: depth, onOpenLink: onOpenLink)
                    .padding(EdgeInsets(top: index > 0 && block.isHeading ? 8 : 0)))
            }
        }
    }
}

struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let depth: Int
    let onOpenLink: ((String) -> Void)?

    var body: some View {
        switch block {
        case .paragraph(let runs):
            AnyView(RichText(runs, onOpenLink: onOpenLink))
        case .heading(let level, let runs):
            AnyView(MarkdownHeading(level: level, runs: runs, onOpenLink: onOpenLink))
        case .quote(let blocks):
            AnyView(MarkdownQuote(blocks: blocks, depth: depth, onOpenLink: onOpenLink))
        case .list(let list):
            AnyView(MarkdownListView(list: list, depth: depth, onOpenLink: onOpenLink))
        case .code(let language, let text):
            AnyView(MarkdownCodeBlock(language: language, text: text))
        case .table(let table):
            AnyView(MarkdownTableView(table: table, onOpenLink: onOpenLink))
        case .rule:
            AnyView(Divider().padding(vertical: 4))
        }
    }
}

private extension MarkdownBlock {
    var isHeading: Bool { if case .heading = self { true } else { false } }
}

struct MarkdownHeading: View {
    let level: Int
    let runs: [RichTextRun]
    let onOpenLink: ((String) -> Void)?

    var body: some View {
        let level = level
        var heading = RichText(runs, onOpenLink: onOpenLink)
        heading.role = .heading(level: level)
        return Box(direction: .column, alignItems: .stretch, spacing: 8) {
            heading.font(SemanticFontRef { Self.token(level: level, theme: $0) })
            // The two top levels rule off their section, as in most readers.
            if level <= 2 { Divider() }
        }
    }

    static func token(level: Int, theme: Theme) -> TextStyleToken {
        let type = theme.typography
        switch level {
        case 1: return type.title
        case 2:
            let size = ((type.title.font.size + type.headline.font.size) / 2).rounded()
            return TextStyleToken(font: type.headline.font.weight(.bold).resized(size),
                                  lineHeight: (size * 1.3).rounded(), letterSpacing: type.headline.letterSpacing)
        case 3: return type.headline
        default:
            let size = level == 4 ? type.body.font.size + 1 : type.body.font.size
            return TextStyleToken(font: type.bodyStrong.font.resized(size), lineHeight: type.body.lineHeight + 2)
        }
    }
}

private extension Font {
    func resized(_ size: Float) -> Font {
        Font(size: size, weight: weight, design: design, family: family, isItalic: isItalic)
    }
}

struct MarkdownQuote: View {
    let blocks: [MarkdownBlock]
    let depth: Int
    let onOpenLink: ((String) -> Void)?

    var body: some View {
        Box(direction: .row, alignItems: .stretch, spacing: 12) {
            Box(direction: .column) {}
                .frame(width: 3)
                .background(.borderStrong)
                .cornerRadius(1.5)
            MarkdownBlocks(blocks: blocks, depth: depth, onOpenLink: onOpenLink)
                .foregroundColor(.onSurfaceMuted)
                .flex(1, shrink: 1, basis: 0)
        }
    }
}
