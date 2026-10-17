private import Foundation

struct TableColumnPlan {
    let indices: [Int]
    let requiredIDs: Set<String>
    let frozenCount: Int
    let availableWidth: Float

    static func resolve<Record>(_ columns: [TableColumn<Record>], widths: [String: Float],
                                overrides: [String: Bool], availableWidth: Float,
                                frozenCount: Int, pinnedIDs: Set<String>) -> Self {
        let frozenCount = min(max(0, frozenCount), columns.count)
        let tracks = tracks(columns, widths: widths)
        let required = pinnedIDs.union(columns.prefix(frozenCount).map(\.id))
        let plan = ColumnVisibilityPlan.resolve(tracks, overrides: overrides, availableWidth: CGFloat(availableWidth), requiredIDs: required)
        let frozenWidth = tracks.prefix(frozenCount).reduce(CGFloat(0)) { $0 + $1.width }
        return Self(indices: plan.indices, requiredIDs: plan.requiredIDs,
                    frozenCount: frozenWidth >= CGFloat(max(0, availableWidth)) ? 0 : frozenCount,
                    availableWidth: max(0, availableWidth))
    }
    static func tracks<Record>(_ columns: [TableColumn<Record>], widths: [String: Float]) -> [ColumnVisibilityTrack] {
        columns.map { .init(id: $0.id, title: $0.title, visibility: $0.visibility,
                            width: CGFloat($0.layout.constrained(widths[$0.id] ?? $0.layout.width))) }
    }
}
