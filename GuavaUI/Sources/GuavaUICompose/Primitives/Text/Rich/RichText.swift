import Foundation
import GuavaUIRuntime

/// A paragraph of styled runs that wrap together: bold, italic, inline code,
/// strikethrough and links in one flow, with the surrounding text style,
/// foreground and `TextScaler` applied once.
///
/// ```swift
/// RichText([
///     RichTextRun("Run "),
///     RichTextRun("guava build", traits: .code),
///     RichTextRun(" or read the "),
///     RichTextRun("guide", link: "https://example.com/guide"),
///     RichTextRun("."),
/// ]) { destination in open(destination) }
/// ```
///
/// Links are underlined body-copy links: they take the pointer cursor and
/// activate on click; `Markdown` builds whole documents from these paragraphs.
public struct RichText: View {
    private let runs: [RichTextRun]
    private let alignment: TextAlignment
    private let onOpenLink: ((String) -> Void)?
    var role = RichTextRole.paragraph

    public init(_ runs: [RichTextRun],
                alignment: TextAlignment = .leading,
                onOpenLink: ((String) -> Void)? = nil) {
        self.runs = runs
        self.alignment = alignment
        self.onOpenLink = onOpenLink
    }

    public init(_ text: String, alignment: TextAlignment = .leading) {
        self.init([RichTextRun(text)], alignment: alignment)
    }

    public var body: some View {
        RichTextReader(runs: runs, alignment: alignment, role: role, onOpenLink: onOpenLink)
    }
}

/// How a paragraph participates in its document.
enum RichTextRole: Hashable {
    case paragraph
    case heading(level: Int)
    /// Monospaced, unwrapped lines inside a horizontally scrolling block.
    case codeBlock
}

struct RichTextPalette: Equatable {
    var text: Color
    var link: Color
    var linkHover: Color
    var codeBackground: Color
    var selection: Color
}

/// Hands the flow layout and the surface one source of truth for styling.
/// Fonts and colours are read from the node when measuring and painting,
/// after modifiers such as `.font(.headline)` have been applied to it.
final class RichTextStyleSource {
    /// The surface: style modifiers may sit on any node above it, and text
    /// style lookup walks towards the root.
    weak var node: Node?
    private let runs: [RichTextRun]
    private let alignment: TextAlignment
    let role: RichTextRole
    /// Link destinations in run order; adjacent runs sharing one form one link.
    let destinations: [String]
    private let linkIndices: [Int?]

    init(runs: [RichTextRun], alignment: TextAlignment, role: RichTextRole) {
        self.runs = runs.filter { !$0.text.isEmpty }
        self.alignment = alignment
        self.role = role
        var destinations: [String] = []
        var previous: String?
        linkIndices = self.runs.map { run in
            defer { previous = run.link }
            guard let destination = run.link else { return nil }
            if previous != destination { destinations.append(destination) }
            return destinations.count - 1
        }
        self.destinations = destinations
    }

    var paragraph: RichParagraph {
        guard let node else { return RichParagraph(spans: []) }
        let theme = node.theme
        let scaler = node.textScaler
        let body = theme.typography.body
        let base: Font = node.textStyleValue(StyleAttachmentKey.font) ?? scaler.scale(body.font)
        let lineHeight: Float = node.textStyleValue(StyleAttachmentKey.lineHeight)
            ?? scaler.scale(body.lineHeight) * base.size / max(1, scaler.scale(body.font.size))
        let mono = theme.typography.mono
        // Inline code keeps the mono token's proportion to body text.
        let codeSize = (base.size * mono.font.size / max(1, body.font.size)).rounded()
        let codeLineHeight = (codeSize * mono.lineHeight / max(1, mono.font.size)).rounded()
        let spans = zip(runs, linkIndices).map { run, link -> RichParagraph.Span in
            var font = base
            if run.traits.contains(.code) || role == .codeBlock {
                font = Font(size: codeSize, weight: base.weight, design: .monospaced, family: mono.font.family)
            }
            if run.traits.contains(.bold) { font = font.weight(.bold) }
            if run.traits.contains(.italic) { font = font.italic() }
            return .init(text: run.text, font: font, lineHeight: role == .codeBlock ? codeLineHeight : lineHeight,
                         traits: run.traits, link: link)
        }
        return RichParagraph(spans: spans, alignment: alignment, wraps: role != .codeBlock)
    }

    var palette: RichTextPalette {
        let theme = node?.theme ?? .defaultDark
        return RichTextPalette(
            text: node?.inheritedForegroundColor ?? theme.colors.onSurface,
            link: theme.colors.accent,
            linkHover: theme.colors.accentHover,
            // A tint of the text colour reads on any surface in either theme.
            codeBackground: theme.colors.onSurface.multipliedAlpha(0.08),
            selection: theme.colors.selection
        )
    }

    var plainText: String { runs.map(\.text).joined() }
}

private struct RichTextReader: _PrimitiveView {
    let runs: [RichTextRun]
    let alignment: TextAlignment
    let role: RichTextRole
    let onOpenLink: ((String) -> Void)?

    func _makeNode() -> Node { let node = Node(); node.isHitTestable = false; return node }
    func _updateNode(_ node: Node) {}
    func _makeLayoutNode() -> LayoutNode? { nil }

    func _children(for node: Node) -> [any View] {
        let source = RichTextStyleSource(runs: runs, alignment: alignment, role: role)
        return [LayoutContainer(RichTextFlowLayout(source: source)) {
            RichTextSurface(source: source, onOpenLink: onOpenLink)
        }]
    }
}

/// Sizes the paragraph from its flow and gives the drawing surface the bounds.
struct RichTextFlowLayout: Layout {
    let source: RichTextStyleSource

    func sizeThatFits(proposal: ProposedViewSize, subviews: [LayoutSubview]) -> CGSize {
        guard let env = TextEnvironmentHolder.current else { return .zero }
        let paragraph = source.paragraph
        let flow = RichTextFlow.layout(paragraph, maxWidth: proposal.width.map(Float.init) ?? .infinity, env: env)
        var width = CGFloat(flow.width.rounded(.up))
        // Centred and trailing lines align inside the offered width.
        if paragraph.alignment != .leading, paragraph.wraps, let offered = proposal.width { width = max(width, offered) }
        return CGSize(width: width, height: CGFloat(flow.height.rounded(.up)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: [LayoutSubview]) {
        for subview in subviews {
            subview.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
        }
    }
}
