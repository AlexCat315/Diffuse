import Foundation

/// Ranking and result projection are shared by rendering, selection and scrolling.
enum CommandEntry: Identifiable {
    case header(String)
    case item(CommandItem)

    var id: String {
        switch self {
        case .header(let title): return "header:\(title)"
        case .item(let item): return "item:\(item.id)"
        }
    }
}

enum CommandSearch {
    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                     locale: Locale(identifier: "en_US_POSIX")).lowercased()
    }

    static func ranked(_ items: [CommandItem], query: String) -> [CommandItem] {
        let terms = normalized(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return items }
        return items.enumerated().compactMap { order, item -> (Int, Int, CommandItem)? in
            guard let score = score(item, terms: terms) else { return nil }
            return (score, order, item)
        }.sorted {
            if $0.2.isEnabled != $1.2.isEnabled { return $0.2.isEnabled }
            return $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 > $1.0
        }.map { $0.2 }
    }

    private static func score(_ item: CommandItem, terms: [String]) -> Int? {
        let title = normalized(item.title)
        let aliases = item.keywords.map(normalized)
        let context = normalized(item.subtitle + " " + item.group)
        var total = 0
        for term in terms {
            if title.hasPrefix(term) { total += 1000 }
            else if title.split(whereSeparator: \.isWhitespace).contains(where: { $0.hasPrefix(term) }) { total += 800 }
            else if title.contains(term) { total += 700 }
            else if aliases.contains(where: { $0.contains(term) }) { total += 300 }
            else if let score = subsequence(title, term) { total += 200 + score }
            else if context.contains(term) { total += 120 }
            else { return nil }
        }
        return total
    }

    private static func subsequence(_ text: String, _ term: String) -> Int? {
        var cursor = text.startIndex
        var skipped = 0
        var previous: String.Index?
        for character in term {
            guard let found = text[cursor...].firstIndex(of: character) else { return nil }
            if let previous { skipped += text.distance(from: previous, to: found) - 1 }
            previous = found
            cursor = text.index(after: found)
        }
        return max(20, 90 - skipped * 5)
    }

    static func entries(_ items: [CommandItem], groupsResults: Bool) -> [CommandEntry] {
        guard groupsResults, Set(items.map(\.group)).count > 1 else { return items.map(CommandEntry.item) }
        var groups: [String] = []
        var buckets: [String: [CommandItem]] = [:]
        for item in items {
            if buckets[item.group] == nil { groups.append(item.group) }
            buckets[item.group, default: []].append(item)
        }
        return groups.flatMap { group in
            (group.isEmpty ? [] : [CommandEntry.header(group)]) + buckets[group, default: []].map(CommandEntry.item)
        }
    }

    /// Arrows wrap; page jumps clamp. Reduce before adding to avoid signed overflow.
    static func destination(count: Int, current: Int?, delta: Int, wraps: Bool) -> Int? {
        guard count > 0 else { return nil }
        guard let current, (0..<count).contains(current) else { return delta < 0 ? count - 1 : 0 }
        if wraps {
            let step = delta % count
            if step >= 0 { return current >= count - step ? current - (count - step) : current + step }
            return current < -step ? count - (-step - current) : current + step
        }
        if delta >= 0 { return current + min(delta, count - 1 - current) }
        return current + max(delta, -current)
    }
}
