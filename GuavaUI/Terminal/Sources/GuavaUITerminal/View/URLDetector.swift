internal import Foundation

/// Finds plain-text URLs on a screen row, for programs that print links
/// without OSC 8 (compilers, `git`, `ls`, logs...).
enum URLDetector {
    struct Match: Equatable {
        var row: Int
        var columns: ClosedRange<Int>
        var url: URL
    }

    private static let pattern = try! NSRegularExpression(
        pattern: #"(?:(?:https?|ftp|file)://|mailto:|www\.)[^\s<>"'`{}|\\^]+"#, options: [.caseInsensitive])

    /// The URL covering `column` on `row`, if any.
    static func match(in frame: TerminalFrame, row: Int, column: Int) -> Match? {
        guard (0..<frame.rows).contains(row), (0..<frame.columns).contains(column) else { return nil }
        // Rebuild the row as UTF-16 text, remembering which column each unit came from.
        var text = ""
        var columnOfUnit: [Int] = []
        for (index, cell) in frame.row(row).enumerated() where cell.width != .spacer {
            let piece = cell.text.isEmpty ? " " : cell.text
            text += piece
            columnOfUnit += Array(repeating: index, count: piece.utf16.count)
        }
        let range = NSRange(text.startIndex..., in: text)
        for result in pattern.matches(in: text, range: range) {
            let length = trimmedLength(text as NSString, result.range)
            guard length > 0 else { continue }
            let first = columnOfUnit[result.range.location]
            let last = columnOfUnit[result.range.location + length - 1]
            let lastCell = frame[row, last]
            let lastColumn = lastCell.width == .wide ? min(frame.columns - 1, last + 1) : last
            guard (first...lastColumn).contains(column) else { continue }
            var link = (text as NSString).substring(with: NSRange(location: result.range.location, length: length))
            if link.lowercased().hasPrefix("www.") { link = "https://" + link }
            guard let url = LinkOpener.url(link) else { continue }
            return Match(row: row, columns: first...lastColumn, url: url)
        }
        return nil
    }

    /// Drops sentence punctuation after a URL, keeping a `)` that closes a
    /// `(` inside it (`https://en.wikipedia.org/wiki/Foo_(bar)`).
    private static func trimmedLength(_ text: NSString, _ range: NSRange) -> Int {
        let candidate = text.substring(with: range)
        var scalars = Array(candidate.utf16)
        let trailing = Set(".,;:!?'\")]}>".utf16)
        while let last = scalars.last, trailing.contains(last) {
            if last == UInt16(UInt8(ascii: ")")) {
                let opens = scalars.filter { $0 == UInt16(UInt8(ascii: "(")) }.count
                let closes = scalars.filter { $0 == UInt16(UInt8(ascii: ")")) }.count
                if opens >= closes { break }
            }
            scalars.removeLast()
        }
        return scalars.count
    }
}
