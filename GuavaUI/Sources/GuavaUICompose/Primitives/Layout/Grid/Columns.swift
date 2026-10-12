import Foundation

/// Width policy for one grid column. An adaptive column expands into as many
/// columns as its allocated width can hold. Children occupy one cell each.
public enum GridColumn: Equatable, Sendable {
    case fixed(CGFloat)
    case flexible(minimum: CGFloat = 0, maximum: CGFloat = .infinity)
    case adaptive(minimum: CGFloat, maximum: CGFloat = .infinity)
}

/// Resolves column widths without measuring or constructing child views.
enum GridTrackResolver {
    static func widths(columns: [GridColumn], availableWidth: CGFloat?, spacing: CGFloat,
                       intrinsicWidths: [CGFloat] = []) -> GridTracks {
        guard !columns.isEmpty else { return GridTracks(groups: [], spacing: 0) }
        let gap = finiteNonnegative(spacing)
        let limits = columns.map { limits(for: $0) }
        var widths = limits.map(\.minimum)
        let finiteWidth = availableWidth.flatMap { $0.isFinite ? max(0, $0) : nil }

        if let finiteWidth {
            var remaining = max(0, finiteWidth - gap * CGFloat(columns.count - 1) - widths.reduce(0, +))
            var active = columns.indices.filter { limits[$0].maximum > widths[$0] }
            // Each pass either finishes distribution or saturates a track.
            // Work is proportional to the small column configuration, never
            // to the number of grid items.
            while remaining > 0, !active.isEmpty {
                let share = remaining / CGFloat(active.count)
                var consumed: CGFloat = 0
                var next: [Int] = []
                for index in active {
                    let addition = min(share, limits[index].maximum - widths[index])
                    widths[index] += addition
                    consumed += addition
                    if widths[index] < limits[index].maximum { next.append(index) }
                }
                guard consumed > 0 else { break }
                remaining = max(0, remaining - consumed)
                active = next
            }
        } else {
            for index in columns.indices {
                guard case .fixed = columns[index] else {
                    let intrinsic = index < intrinsicWidths.count ? intrinsicWidths[index] : 0
                    widths[index] = min(limits[index].maximum, max(widths[index], finiteNonnegative(intrinsic)))
                    continue
                }
            }
        }

        var resolved: [GridTracks.Group] = []
        resolved.reserveCapacity(columns.count)
        for index in columns.indices {
            guard case let .adaptive(rawMinimum, rawMaximum) = columns[index] else {
                resolved.append(.init(width: widths[index], count: 1))
                continue
            }
            let minimum = max(1, finiteNonnegative(rawMinimum))
            let maximum = upperBound(rawMaximum, minimum: minimum)
            let capacity = max(1, floor((widths[index] + gap) / (minimum + gap)))
            // Keep adaptive tracks as repeated groups, so an unusually large
            // proposal never allocates one entry per empty cell.
            let countLimit = (Int.max / 2) / columns.count
            let count = Int(min(capacity, CGFloat(countLimit)))
            let cellWidth = max(minimum, min(maximum, (widths[index] - gap * CGFloat(count - 1)) / CGFloat(count)))
            resolved.append(.init(width: cellWidth, count: count))
        }
        return GridTracks(groups: resolved, spacing: gap)
    }

    static func finiteNonnegative(_ value: CGFloat) -> CGFloat {
        value.isFinite ? max(0, value) : 0
    }

    private static func upperBound(_ value: CGFloat, minimum: CGFloat) -> CGFloat {
        value.isNaN ? minimum : max(minimum, value)
    }

    private static func limits(for column: GridColumn) -> (minimum: CGFloat, maximum: CGFloat) {
        switch column {
        case let .fixed(width):
            let width = finiteNonnegative(width)
            return (width, width)
        case let .flexible(minimum, maximum):
            let minimum = finiteNonnegative(minimum)
            return (minimum, upperBound(maximum, minimum: minimum))
        case let .adaptive(minimum, _):
            return (max(1, finiteNonnegative(minimum)), .infinity)
        }
    }
}

/// Adaptive repetitions stay compact. Lookup visits only the authored column
/// policies; total width and count do not iterate over empty adaptive cells.
struct GridTracks: Sequence {
    struct Group {
        let width: CGFloat
        let count: Int
    }
    private let groups: [Group]
    let count: Int
    let totalWidth: CGFloat
    var isEmpty: Bool { count == 0 }

    init(groups: [Group], spacing: CGFloat) {
        self.groups = groups
        count = groups.reduce(0) { $0 + $1.count }
        totalWidth = groups.reduce(0) { $0 + $1.width * CGFloat($1.count) }
            + spacing * CGFloat(Swift.max(0, count - 1))
    }

    subscript(index: Int) -> CGFloat {
        precondition(index >= 0 && index < count, "Grid column index out of bounds")
        var remaining = index
        for group in groups {
            if remaining < group.count { return group.width }
            remaining -= group.count
        }
        preconditionFailure("Grid column index out of bounds")
    }

    func makeIterator() -> Iterator { Iterator(groups: groups) }

    struct Iterator: IteratorProtocol {
        fileprivate let groups: [Group]
        private var groupIndex = 0
        private var repetition = 0

        fileprivate init(groups: [Group]) { self.groups = groups }

        mutating func next() -> CGFloat? {
            guard groupIndex < groups.count else { return nil }
            let group = groups[groupIndex]
            repetition += 1
            if repetition == group.count {
                repetition = 0
                groupIndex += 1
            }
            return group.width
        }
    }
}
