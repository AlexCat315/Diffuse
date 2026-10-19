import Foundation
import GuavaUIRuntime

/// The cells one panel's keys move between: their extent, one step, how
/// many sit in a row, and the page that PageUp/PageDown and Home/End use.
struct CalendarCells {
    let period: Foundation.Calendar.Component
    let unit: Foundation.Calendar.Component
    let unitCount: Int
    let columns: Int
    let page: Foundation.Calendar.Component
    let pageCount: Int

    init(panel: CalendarPanel, granularity: CalendarGranularity) {
        switch (panel, granularity) {
        case (.days, .week):
            period = .weekOfYear; unit = .day; unitCount = 7; columns = 1; page = .month; pageCount = 1
        case (.days, _):
            period = .day; unit = .day; unitCount = 1; columns = 7; page = .month; pageCount = 1
        case (.months, _):
            period = .month; unit = .month; unitCount = 1; columns = 3; page = .year; pageCount = 1
        case (.years, _):
            period = .year; unit = .year; unitCount = 1; columns = 3; page = .year; pageCount = 12
        }
    }

    func start(_ date: Date, calendar: Foundation.Calendar) -> Date {
        CalendarGrid.interval(of: period, containing: date, calendar: calendar).start
    }

    func isAvailable(_ date: Date, calendar: Foundation.Calendar, availability: DateAvailability) -> Bool {
        period == .day ? availability.contains(date, calendar: calendar)
            : CalendarGrid.hasAvailableDay(in: CalendarGrid.interval(of: period, containing: date, calendar: calendar),
                                           calendar: calendar, availability: availability)
    }

    /// The page containing `date`: a month of days or weeks, a year of
    /// months, or a twelve-year page of years.
    func bounds(_ date: Date, calendar: Foundation.Calendar) -> DateInterval {
        pageCount == 12 ? CalendarGrid.yearPage(containing: date, calendar: calendar)
            : CalendarGrid.interval(of: page, containing: date, calendar: calendar)
    }
}

/// Keyboard destinations are transient; only activation writes the selection.
enum CalendarNavigation {
    case step(Int)
    case page(Int)
    case first
    case last

    init?(scancode: UInt32, columns: Int) {
        switch scancode {
        case Scancode.arrowLeft: self = .step(-1)
        case Scancode.arrowRight: self = .step(1)
        case Scancode.arrowUp: self = .step(-columns)
        case Scancode.arrowDown: self = .step(columns)
        case Scancode.home: self = .first
        case Scancode.end: self = .last
        case Scancode.pageUp: self = .page(-1)
        case Scancode.pageDown: self = .page(1)
        default: return nil
        }
    }

    func destination(from date: Date, cells: CalendarCells, calendar: Foundation.Calendar,
                     availability: DateAvailability) -> Date? {
        switch self {
        case .step(let count):
            var candidate = date
            for _ in 0..<3660 {
                guard let next = calendar.date(byAdding: cells.unit, value: count * cells.unitCount, to: candidate) else { return nil }
                candidate = next
                if cells.isAvailable(candidate, calendar: calendar, availability: availability) {
                    return cells.start(candidate, calendar: calendar)
                }
            }
            return nil
        case .first, .last:
            let direction = { if case .first = self { return 1 } else { return -1 } }()
            let bounds = cells.bounds(date, calendar: calendar)
            let origin = direction == 1 ? bounds.start : bounds.end.addingTimeInterval(-1)
            return scan(from: origin, direction: direction, within: bounds, cells: cells,
                        calendar: calendar, availability: availability)
        case .page(let count):
            guard let target = calendar.date(byAdding: cells.page, value: count * cells.pageCount, to: date) else { return nil }
            let bounds = cells.bounds(target, calendar: calendar)
            let direction = count > 0 ? 1 : -1
            return scan(from: target, direction: direction, within: bounds, cells: cells, calendar: calendar, availability: availability)
                ?? scan(from: target, direction: -direction, within: bounds, cells: cells, calendar: calendar, availability: availability)
        }
    }

    /// The first available cell overlapping `bounds`, walking from `date`.
    private func scan(from date: Date, direction: Int, within bounds: DateInterval, cells: CalendarCells,
                      calendar: Foundation.Calendar, availability: DateAvailability) -> Date? {
        var candidate = cells.start(date, calendar: calendar)
        for _ in 0..<400 {
            let extent = CalendarGrid.interval(of: cells.period, containing: candidate, calendar: calendar)
            guard extent.end > bounds.start, extent.start < bounds.end else { return nil }
            if cells.isAvailable(candidate, calendar: calendar, availability: availability) { return candidate }
            guard let next = calendar.date(byAdding: cells.unit, value: direction * cells.unitCount, to: candidate) else { return nil }
            candidate = cells.start(next, calendar: calendar)
        }
        return nil
    }
}
