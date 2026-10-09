import Foundation

/// Turns SourceKit-LSP hover markup into renderable plain text.
///
/// Documentation arrives as Markdown with a fenced Swift declaration followed
/// by prose. The popup draws with a single fixed-width font, so inline styling
/// has to be reduced to something legible while keeping the declaration the
/// most prominent part.
public enum ScriptMarkdownText {

    /// Doc-comment section headings that add nothing once the declaration and
    /// prose are already separated visually.
    private static let droppedHeadings: Set<String> = [
        "declaration", "summary", "overview", "discussion", "parameters", "parameter",
        "returns", "return", "throws", "note", "precondition", "important", "see also",
    ]

    /// Reduces markup to `declaration\n\nprose`, dropping fenced block markers
    /// and inline styling. Whitespace-only input yields an empty string.
    public static func plainSummary(_ markdown: String) -> String {
        var declaration: [String] = []
        var prose: [String] = []
        var isInsideCodeBlock = false

        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = String(rawLine).trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                isInsideCodeBlock.toggle()
                continue
            }
            guard !trimmed.isEmpty else { continue }
            if isInsideCodeBlock {
                declaration.append(trimmed)
            } else {
                let cleaned = stripInlineMarkup(trimmed)
                guard !cleaned.isEmpty else { continue }
                guard !droppedHeadings.contains(cleaned.lowercased()) else { continue }
                prose.append(cleaned)
            }
        }

        var sections: [String] = []
        if !declaration.isEmpty { sections.append(declaration.joined(separator: " ")) }
        let summary = collapseSentences(prose)
        if !summary.isEmpty { sections.append(summary) }
        return sections.joined(separator: "\n\n")
    }

    /// Collapses Soft-wrapped prose into single paragraphs while preserving
    /// Markdown list structure, which doc comments rely on for parameters.
    private static func collapseSentences(_ lines: [String]) -> String {
        var paragraphs: [String] = []
        var current: [String] = []

        func flush() {
            guard !current.isEmpty else { return }
            paragraphs.append(current.joined(separator: " "))
            current.removeAll()
        }

        for line in lines {
            let isBullet = line.hasPrefix("• ") || line.hasPrefix("- ") || line.hasPrefix("* ")
            if isBullet {
                flush()
                let body = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if !body.isEmpty { paragraphs.append("• \(body)") }
            } else {
                current.append(line)
            }
        }
        flush()
        return paragraphs.joined(separator: "\n")
    }

    private static func stripInlineMarkup(_ line: String) -> String {
        var result = line
        // Section headings (### Declaration) carry no information once the
        // declaration itself is hoisted above the prose.
        while result.hasPrefix("#") {
            result = String(result.dropFirst())
        }
        result = result.trimmingCharacters(in: .whitespaces)
        for token in ["**", "__", "`", "*", "_"] {
            result = result.replacingOccurrences(of: token, with: "")
        }
        // [label](target) → label
        if let expression = try? NSRegularExpression(pattern: #"\[([^\]]*)\]\([^\)]*\)"#) {
            let range = NSRange(result.startIndex..., in: result)
            result = expression.stringByReplacingMatches(in: result,
                                                         range: range,
                                                         withTemplate: "$1")
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}
