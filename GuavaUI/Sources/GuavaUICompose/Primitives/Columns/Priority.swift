internal import Foundation

/// Required columns stay available. Equal priorities preserve authored order.
public enum ColumnVisibility: Equatable, Sendable {
    case required
    case automatic(priority: Int = 0)

    var priority: Int {
        switch self {
        case .required: Int.max
        case .automatic(let value): value
        }
    }
}

/// Adapter values for column containers, independent of records and layouts.
struct ColumnVisibilityTrack {
    let id: String
    let title: String
    let visibility: ColumnVisibility
    let width: CGFloat
}

struct ColumnVisibilityPlan {
    let indices: [Int]
    let requiredIDs: Set<String>

    static func resolve(_ columns: [ColumnVisibilityTrack], overrides: [String: Bool],
                        availableWidth: CGFloat, spacing: CGFloat = 0, requiredIDs: Set<String> = []) -> Self {
        let protected = Set(columns.indices.filter { columns[$0].visibility == .required || requiredIDs.contains(columns[$0].id) })
        var required = protected.union(columns.indices.filter { overrides[columns[$0].id] == true })
        var shown = Set(columns.indices.filter { required.contains($0) || overrides[columns[$0].id] != false })
        let candidates = columns.indices.filter { !required.contains($0) && overrides[columns[$0].id] == nil }.sorted {
            let lhs = columns[$0].visibility.priority, rhs = columns[$1].visibility.priority
            return lhs == rhs ? $0 > $1 : lhs < rhs
        }
        if required.isEmpty, let anchor = shown.min(by: {
            let lhs = columns[$0].visibility.priority, rhs = columns[$1].visibility.priority
            return lhs == rhs ? $0 < $1 : lhs > rhs
        }) ?? columns.indices.first {
            required.insert(anchor); shown.insert(anchor)
        }
        var width = columns.indices.filter { shown.contains($0) }.reduce(CGFloat(0)) { $0 + columns[$1].width }
            + spacing * CGFloat(max(0, shown.count - 1))
        for index in candidates where width > max(0, availableWidth) && !required.contains(index) {
            shown.remove(index); width -= columns[index].width + (shown.isEmpty ? 0 : spacing)
        }
        return Self(indices: columns.indices.filter { shown.contains($0) }, requiredIDs: Set(protected.map { columns[$0].id }))
    }
}
