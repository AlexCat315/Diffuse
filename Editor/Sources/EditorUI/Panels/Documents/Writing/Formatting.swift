internal import Foundation
internal import GuavaUI
internal import GuavaUIRuntime

/// Markdown formatting commands as pure edits on a buffer and selection, so
/// the toolbar, shortcuts and tests share one implementation.
enum MarkdownFormat: String, CaseIterable {
    case bold, italic, strikethrough, code, link, heading, bulletList, numberedList, taskList, quote

    var title: String {
        switch self {
        case .bold: "Bold"
        case .italic: "Italic"
        case .strikethrough: "Strikethrough"
        case .code: "Inline Code"
        case .link: "Link"
        case .heading: "Heading"
        case .bulletList: "Bulleted List"
        case .numberedList: "Numbered List"
        case .taskList: "Task List"
        case .quote: "Quote"
        }
    }

    var icon: BundleImageResource {
        switch self {
        case .bold: UIIcons.Text.bold
        case .italic: UIIcons.Text.italic
        case .strikethrough: UIIcons.Action.minus
        case .code: UIIcons.Editor.code
        case .link: UIIcons.Action.link
        case .heading: UIIcons.Text.heading
        case .bulletList: UIIcons.Text.list
        case .numberedList: UIIcons.Text.listOrdered
        case .taskList: UIIcons.Shape.squareCheck
        case .quote: UIIcons.Text.pilcrow
        }
    }

    /// The letter used with the primary modifier, when the command has one.
    var shortcutLetter: Character? {
        switch self {
        case .bold: "b"
        case .italic: "i"
        case .link: "k"
        default: nil
        }
    }

    struct Edit: Equatable {
        let range: Range<Int>
        let replacement: String
        /// Where the caret goes afterwards, in the edited buffer.
        let caret: Int
    }

    /// The edit for this command at `selection` (an empty range is the caret).
    func edit(in buffer: TextBuffer, selection: Range<Int>) -> Edit {
        switch self {
        case .bold: return wrap(buffer, selection, "**", "**", placeholder: "bold text")
        case .italic: return wrap(buffer, selection, "_", "_", placeholder: "italic text")
        case .strikethrough: return wrap(buffer, selection, "~~", "~~", placeholder: "text")
        case .code: return wrap(buffer, selection, "`", "`", placeholder: "code")
        case .link:
            let text = buffer.substring(characterRange: selection)
            let label = text.isEmpty ? "link" : text
            let replacement = "[\(label)](https://)"
            // Leave the caret inside the parentheses, ready for the address.
            return Edit(range: selection, replacement: replacement,
                        caret: selection.lowerBound + replacement.count - 1)
        case .heading: return prefixLines(buffer, selection) { line, _ in
            // # → ## → ### → plain, the way writing apps cycle heading levels.
            let level = line.prefix { $0 == "#" }.count
            let body = level > 0 ? String(line.dropFirst(level).drop { $0 == " " }) : line
            return level == 0 ? "# " + body : level < 3 ? String(repeating: "#", count: level + 1) + " " + body : body
        }
        case .bulletList: return togglePrefix(buffer, selection, "- ")
        case .taskList: return togglePrefix(buffer, selection, "- [ ] ")
        case .quote: return togglePrefix(buffer, selection, "> ")
        case .numberedList:
            return prefixLines(buffer, selection) { line, index in
                if let marker = line.range(of: #"^\d+\. "#, options: .regularExpression) {
                    return String(line[marker.upperBound...])
                }
                return "\(index + 1). " + line
            }
        }
    }

    private func wrap(_ buffer: TextBuffer, _ selection: Range<Int>, _ open: String, _ close: String,
                      placeholder: String) -> Edit {
        let text = buffer.substring(characterRange: selection)
        // Already wrapped: unwrap.
        if text.count >= open.count + close.count, text.hasPrefix(open), text.hasSuffix(close) {
            let inner = String(text.dropFirst(open.count).dropLast(close.count))
            return Edit(range: selection, replacement: inner, caret: selection.lowerBound + inner.count)
        }
        let before = selection.lowerBound >= open.count
            ? buffer.substring(characterRange: (selection.lowerBound - open.count)..<selection.lowerBound) : ""
        let after = buffer.substring(characterRange: selection.upperBound..<min(buffer.characterCount, selection.upperBound + close.count))
        if !text.isEmpty, before == open, after == close {
            let range = (selection.lowerBound - open.count)..<(selection.upperBound + close.count)
            return Edit(range: range, replacement: text, caret: range.lowerBound + text.count)
        }
        let body = text.isEmpty ? placeholder : text
        return Edit(range: selection, replacement: open + body + close,
                    caret: selection.lowerBound + open.count + body.count)
    }

    private func togglePrefix(_ buffer: TextBuffer, _ selection: Range<Int>, _ prefix: String) -> Edit {
        let lines = lineSpan(buffer, selection)
        let all = lines.text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let filled = all.filter { !$0.isEmpty }
        let remove = !filled.isEmpty && filled.allSatisfy { $0.hasPrefix(prefix) }
        return prefixLines(buffer, selection) { line, _ in
            if remove { return line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : line }
            return line.isEmpty && all.count > 1 ? line : prefix + line
        }
    }

    private func prefixLines(_ buffer: TextBuffer, _ selection: Range<Int>,
                             transform: (String, Int) -> String) -> Edit {
        let span = lineSpan(buffer, selection)
        let separator = span.text.contains("\r\n") ? "\r\n" : "\n"
        let replacement = span.text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated()
            .map { transform(String($0.element), $0.offset) }.joined(separator: separator)
        return Edit(range: span.range, replacement: replacement, caret: span.range.lowerBound + replacement.count)
    }

    /// Whole lines touched by the selection.
    private func lineSpan(_ buffer: TextBuffer, _ selection: Range<Int>) -> (range: Range<Int>, text: String) {
        let first = buffer.lineIndex(forCharacterIndex: selection.lowerBound)
        let lastIndex = selection.isEmpty ? selection.lowerBound : selection.upperBound - 1
        let last = buffer.lineIndex(forCharacterIndex: max(selection.lowerBound, lastIndex))
        let range = buffer.lineRange(forLine: first).lowerBound..<buffer.lineRange(forLine: last).upperBound
        return (range, buffer.substring(characterRange: range))
    }
}
