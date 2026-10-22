internal import Foundation

/// Counts shown while writing. CJK characters count as words, the way
/// writers of those languages measure length.
struct DocumentStatistics: Equatable {
    var words = 0
    var characters = 0
    var paragraphs = 0

    init(_ text: Substring) {
        var inWord = false
        var lineHasText = false
        var previousLineBlank = true
        for character in text {
            if character.isNewline {
                if lineHasText && previousLineBlank { paragraphs += 1 }
                previousLineBlank = !lineHasText
                lineHasText = false
                inWord = false
                continue
            }
            if character.isWhitespace { inWord = false; continue }
            characters += 1
            lineHasText = true
            if Self.isIdeographic(character) {
                words += 1
                inWord = false
            } else if character.isLetter || character.isNumber {
                if !inWord { words += 1 }
                inWord = true
            } else {
                inWord = false
            }
        }
        if lineHasText && previousLineBlank { paragraphs += 1 }
    }

    /// About 250 words a minute, never less than one minute for any text.
    var readingMinutes: Int { words == 0 ? 0 : max(1, Int((Double(words) / 250).rounded())) }

    private static func isIdeographic(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0x20000...0x2FA1F: return true
        default: return false
        }
    }
}

/// One Markdown heading, with the character index of its line.
struct DocumentHeading: Equatable {
    let level: Int
    let title: String
    let characterIndex: Int

    /// ATX headings (`#` … `######`), skipping fenced code blocks.
    static func parse(_ text: String) -> [DocumentHeading] {
        var headings: [DocumentHeading] = []
        var index = 0
        var fence: Substring?
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            defer { index += line.count + 1 }
            let trimmed = line.drop { $0 == " " }
            if let marker = fence {
                if trimmed.hasPrefix(marker) { fence = nil }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { fence = trimmed.prefix(3); continue }
            guard line.count - trimmed.count < 4, trimmed.hasPrefix("#") else { continue }
            let level = trimmed.prefix { $0 == "#" }.count
            let rest = trimmed.dropFirst(level)
            guard level <= 6, rest.isEmpty || rest.first == " " else { continue }
            var title = rest.trimmingCharacters(in: .whitespaces)
            while title.hasSuffix("#") { title = String(title.dropLast()).trimmingCharacters(in: .whitespaces) }
            guard !title.isEmpty else { continue }
            headings.append(DocumentHeading(level: level, title: title, characterIndex: index))
        }
        return headings
    }
}
