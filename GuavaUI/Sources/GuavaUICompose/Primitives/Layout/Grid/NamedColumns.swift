internal import Foundation

enum GridNamedColumns {
    static func tracks(_ columns: [GridColumn]) -> [ColumnVisibilityTrack]? {
        let tracks: [ColumnVisibilityTrack] = columns.compactMap { column in
            guard case let .named(id, title, sizing, visibility) = column else { return nil }
            precondition(!id.isEmpty && !title.isEmpty, "Named Grid columns require an ID and title")
            switch sizing {
            case .fixed, .flexible: break
            case .adaptive, .named: preconditionFailure("Named Grid columns use fixed or flexible sizing")
            }
            return .init(id: id, title: title, visibility: visibility,
                         width: GridTrackResolver.minimumWidth(columns: [sizing], spacing: 0))
        }
        guard !tracks.isEmpty else { return nil }
        precondition(tracks.count == columns.count, "Use named columns for every field in a named Grid")
        precondition(Set(tracks.map(\.id)).count == tracks.count, "Grid column IDs must be unique")
        return tracks
    }

    static func minimumWidth(_ columns: [GridColumn], overrides: [String: Bool], spacing: CGFloat) -> CGFloat {
        guard let tracks = tracks(columns) else { return GridTrackResolver.minimumWidth(columns: columns, spacing: spacing) }
        let required = ColumnVisibilityPlan.resolve(tracks, overrides: overrides, availableWidth: 0, spacing: spacing)
        return required.indices.reduce(CGFloat(0)) { $0 + tracks[$1].width }
            + spacing * CGFloat(max(0, required.indices.count - 1))
    }
}
