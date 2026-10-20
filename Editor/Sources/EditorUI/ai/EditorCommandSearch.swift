internal import EditorCore
private import Foundation

enum EditorCommandSearch {
    /// The palette lists the same catalog entries as the menus, minus the
    /// entries that only open the palette itself.
    static func commands(app: EditorApplication) -> [EditorCommandEntry] {
        EditorCommandCatalog.make(EditorCommandContext(app: app)).entries.filter(\.inPalette)
    }

    /// Exact and word matches precede subsequence matches. Multi-word queries
    /// must match every token, including localized labels, IDs and paths.
    static func score(_ query: String, in text: String) -> Int? {
        let haystack = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let tokens = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: { $0.isWhitespace })
        var total = 0
        for token in tokens {
            if haystack == token { total += 100 }
            else if haystack.contains(token) { total += 60 }
            else {
                var cursor = haystack.startIndex
                for character in token {
                    guard let found = haystack[cursor...].firstIndex(of: character) else { return nil }
                    cursor = haystack.index(after: found)
                }
                total += 10
            }
        }
        return total
    }
}
