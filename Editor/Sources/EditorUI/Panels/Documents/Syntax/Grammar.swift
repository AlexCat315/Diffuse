internal import EditorCore
internal import Foundation

/// A language's declarative grammar compiled for the host. Rules run in
/// order; characters an earlier rule claimed are never recoloured.
struct DocumentGrammar: @unchecked Sendable {
    private struct Rule {
        let expression: NSRegularExpression
        let token: LanguageSyntaxRule.Token
    }

    private let rules: [Rule]

    init?(rules: [LanguageSyntaxRule]) {
        guard !rules.isEmpty else { return nil }
        var compiled: [Rule] = []
        compiled.reserveCapacity(rules.count)
        for rule in rules {
            guard let expression = try? NSRegularExpression(pattern: rule.pattern,
                                                            options: [.anchorsMatchLines]) else {
                return nil
            }
            compiled.append(Rule(expression: expression, token: rule.token))
        }
        self.rules = compiled
    }

    /// UTF-8 ranges and the token each carries, in document order. Adjacent
    /// ranges with the same token are merged.
    func tokens(in text: String) -> [(range: Range<Int>, token: LanguageSyntaxRule.Token)] {
        guard !text.isEmpty else { return [] }
        let fullRange = NSRange(location: 0, length: text.utf16.count)
        var occupied = IndexSet()
        var claimed: [(range: NSRange, token: LanguageSyntaxRule.Token)] = []

        for rule in rules {
            for match in rule.expression.matches(in: text, options: [], range: fullRange)
            where match.range.length > 0 {
                let matchRange = IndexSet(integersIn: match.range.location..<NSMaxRange(match.range))
                let available = matchRange.subtracting(occupied)
                guard !available.isEmpty else { continue }
                for range in available.rangeView {
                    claimed.append((NSRange(location: range.lowerBound, length: range.count),
                                    rule.token))
                }
                occupied.formUnion(matchRange)
            }
        }

        claimed.sort { $0.range.location < $1.range.location }
        var merged: [(range: NSRange, token: LanguageSyntaxRule.Token)] = []
        merged.reserveCapacity(claimed.count)
        for entry in claimed {
            if let last = merged.last,
               NSMaxRange(last.range) == entry.range.location,
               last.token == entry.token {
                merged[merged.count - 1].range.length += entry.range.length
            } else {
                merged.append(entry)
            }
        }

        let offsets = UTF16ToUTF8Offsets(text)
        return merged.map {
            (offsets.utf8Offset(forUTF16: $0.range.location)
                ..< offsets.utf8Offset(forUTF16: NSMaxRange($0.range)),
             $0.token)
        }
    }
}

/// Converts the UTF-16 coordinates regular expressions use to the UTF-8
/// offsets the editor addresses text with. Built once per document.
private struct UTF16ToUTF8Offsets {
    private let offsets: [Int]

    init(_ text: String) {
        var offsets: [Int] = []
        offsets.reserveCapacity(text.utf16.count + 1)
        var byteOffset = 0
        for character in text {
            let utf16Count = character.unicodeScalars.reduce(0) {
                $0 + ($1.value > 0xFFFF ? 2 : 1)
            }
            let byteCount = character.unicodeScalars.reduce(0) { $0 + Self.utf8Count($1.value) }
            offsets.append(byteOffset)
            if utf16Count > 1 {
                for _ in 1..<utf16Count { offsets.append(byteOffset + byteCount) }
            }
            byteOffset += byteCount
        }
        offsets.append(byteOffset)
        self.offsets = offsets
    }

    func utf8Offset(forUTF16 offset: Int) -> Int {
        offsets[min(max(0, offset), offsets.count - 1)]
    }

    private static func utf8Count(_ value: UInt32) -> Int {
        switch value {
        case 0...0x7F: 1
        case 0x80...0x7FF: 2
        case 0x800...0xFFFF: 3
        default: 4
        }
    }
}
