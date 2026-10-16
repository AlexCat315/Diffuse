/// Required columns stay available. Automatic columns yield space from lower
/// to higher priority; equal priorities preserve the earlier authored column.
public enum TableColumnVisibility: Equatable, Sendable {
    case required
    case automatic(priority: Int = 0)
}

struct TableColumnPlan {
    let indices: [Int]
    let requiredIDs: Set<String>
    let frozenCount: Int
    let availableWidth: Float

    static func resolve<Record>(_ columns: [TableColumn<Record>], widths: [String: Float],
                                overrides: [String: Bool], availableWidth: Float,
                                frozenCount: Int, pinnedIDs: Set<String>) -> Self {
        let frozenCount = min(max(0, frozenCount), columns.count)
        let sizes = columns.map { $0.layout.constrained(widths[$0.id] ?? $0.layout.width) }
        let protected = Set(columns.indices.filter {
            $0 < frozenCount || columns[$0].visibility == .required || pinnedIDs.contains(columns[$0].id)
        })
        var required = protected.union(columns.indices.filter { overrides[columns[$0].id] == true })
        var shown = Set(columns.indices.filter { required.contains($0) || overrides[columns[$0].id] != false })
        let candidates = columns.indices.filter {
            !required.contains($0) && overrides[columns[$0].id] == nil
        }.sorted {
            let lhs = columns[$0].visibility.priority, rhs = columns[$1].visibility.priority
            return lhs == rhs ? $0 > $1 : lhs < rhs
        }
        // A table always has a reachable column, even if all overrides hide it.
        if required.isEmpty, let anchor = shown.min(by: {
            let lhs = columns[$0].visibility.priority, rhs = columns[$1].visibility.priority
            return lhs == rhs ? $0 < $1 : lhs > rhs
        }) ?? columns.indices.first {
            required.insert(anchor); shown.insert(anchor)
        }
        var width = columns.indices.filter { shown.contains($0) }.reduce(Float(0)) { $0 + sizes[$1] }
        for index in candidates where width > max(0, availableWidth) && !required.contains(index) {
            shown.remove(index); width -= sizes[index]
        }
        let indices = columns.indices.filter { shown.contains($0) }
        let frozenWidth = sizes.prefix(frozenCount).reduce(0, +)
        // Oversized required columns must remain reachable by horizontal scroll.
        // Their visibility is unchanged when freezing cannot leave a viewport.
        let effectiveFrozenCount = frozenWidth >= max(0, availableWidth) ? 0 : frozenCount
        return Self(indices: indices, requiredIDs: Set(protected.map { columns[$0].id }),
                    frozenCount: effectiveFrozenCount, availableWidth: max(0, availableWidth))
    }
}

private extension TableColumnVisibility {
    var priority: Int {
        switch self {
        case .required: Int.max
        case .automatic(let priority): priority
        }
    }
}
