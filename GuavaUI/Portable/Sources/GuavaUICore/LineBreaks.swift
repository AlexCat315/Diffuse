/// Line-break opportunities for mixed Latin and CJK prose: after spaces,
/// around ideographs (with the common kinsoku exceptions) and after hyphens
/// or slashes inside long words such as URLs.
enum RichTextBreaks {
    /// UTF-8 offsets before which a soft line break is allowed.
    static func opportunities(in text: String) -> Set<Int> {
        var result: Set<Int> = []
        var offset = 0
        var previous: Character?
        for character in text {
            defer { offset += character.utf8.count; previous = character }
            guard let before = previous else { continue }
            if isSpace(character) || character.isNewline { continue }
            if isSpace(before) {
                result.insert(offset)
            } else if isIdeographic(character) || isIdeographic(before) {
                if !closing.contains(character), !opening.contains(before) { result.insert(offset) }
            } else if (before == "-" || before == "/" || before == "\u{2014}"),
                      character.isLetter || character.isNumber {
                result.insert(offset)
            }
        }
        return result
    }

    static func isSpace(_ character: Character) -> Bool { character == " " || character == "\t" }

    private static func isIdeographic(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first?.value else { return false }
        switch scalar {
        case 0x2E80...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF00...0xFFEF, 0x20000...0x3FFFF:
            return true
        default:
            return false
        }
    }

    /// Never starts a line.
    private static let closing: Set<Character> = [
        "，", "。", "、", "；", "：", "？", "！", "）", "」", "』", "】", "〉", "》", "〕", "…", "·",
        ",", ".", ";", ":", "!", "?", ")", "]", "}", "%",
    ]
    /// Never ends a line.
    private static let opening: Set<Character> = ["（", "「", "『", "【", "〈", "《", "〔", "(", "[", "{"]
}
