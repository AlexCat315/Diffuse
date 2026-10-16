/// Chooses source text before shaping the visible line, preserving ligatures,
/// fallback fonts and extended grapheme clusters instead of slicing glyphs.
enum SingleLineText {
    static func fitting(_ source: String, width: Float, measure: (String) -> Float) -> String {
        let text = source.split(whereSeparator: \.isNewline).joined(separator: " ")
        guard width.isFinite else { return text }
        guard width > 0 else { return "" }
        guard measure(text) > width else { return text }
        guard measure("…") <= width else { return "" }
        let characters = Array(text)
        var lower = 0, upper = characters.count
        while lower < upper {
            let count = (lower + upper + 1) / 2
            if measure(String(characters.prefix(count)) + "…") <= width { lower = count }
            else { upper = count - 1 }
        }
        return String(characters.prefix(lower)) + "…"
    }
}
