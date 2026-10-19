import Foundation
import GuavaUIRuntime

/// What one selection covers. The bound date is the period's first day, and
/// any date inside the period shows as selected, so callers may store either.
public enum CalendarGranularity: Sendable, Hashable {
    case day
    case week
    case month
    case year

    var component: Foundation.Calendar.Component {
        switch self {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        }
    }

    /// The most detailed panel this granularity can browse.
    var basePanel: CalendarPanel {
        switch self {
        case .day, .week: .days
        case .month: .months
        case .year: .years
        }
    }

    /// Trigger and accessibility text for a selected period.
    func label(for date: Date, calendar: Foundation.Calendar, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone; formatter.locale = locale
        switch self {
        case .day:
            formatter.dateStyle = .medium
            return formatter.string(from: date)
        case .week:
            let week = calendar.component(.weekOfYear, from: date)
            let year = calendar.component(.yearForWeekOfYear, from: date)
            return "Week \(week), \(year)"
        case .month:
            formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
            return formatter.string(from: date)
        case .year:
            formatter.setLocalizedDateFormatFromTemplate("yyyy")
            return formatter.string(from: date)
        }
    }
}

/// The browsing level: a month of days, a year of months, or twelve years.
enum CalendarPanel: Int, Comparable {
    case days
    case months
    case years

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    var parent: CalendarPanel? { CalendarPanel(rawValue: rawValue + 1) }
    var child: CalendarPanel? { CalendarPanel(rawValue: rawValue - 1) }
}

extension CalendarGrid {
    static func interval(of component: Foundation.Calendar.Component, containing date: Date,
                         calendar: Foundation.Calendar) -> DateInterval {
        calendar.dateInterval(of: component, for: date)
            ?? DateInterval(start: calendar.startOfDay(for: date), duration: 86_400)
    }

    static func start(of granularity: CalendarGranularity, containing date: Date, calendar: Foundation.Calendar) -> Date {
        interval(of: granularity.component, containing: date, calendar: calendar).start
    }

    /// The twelve-year page containing `date`, aligned so pages never overlap.
    static func yearPage(containing date: Date, calendar: Foundation.Calendar) -> DateInterval {
        let year = calendar.component(.year, from: date)
        let first = year - ((year % 12) + 12) % 12
        let start = calendar.date(from: DateComponents(year: first, month: 1, day: 1)) ?? date
        let end = calendar.date(byAdding: .year, value: 12, to: start) ?? start
        return DateInterval(start: start, end: end)
    }

    /// True when any day of the interval is available.
    static func hasAvailableDay(in interval: DateInterval, calendar: Foundation.Calendar,
                                availability: DateAvailability) -> Bool {
        if let minimum = availability.minimum, interval.end <= calendar.startOfDay(for: minimum) { return false }
        if let maximum = availability.maximum, interval.start > calendar.startOfDay(for: maximum) { return false }
        var day = interval.start
        while day < interval.end {
            if availability.contains(day, calendar: calendar) { return true }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { return false }
            day = next
        }
        return false
    }
}
