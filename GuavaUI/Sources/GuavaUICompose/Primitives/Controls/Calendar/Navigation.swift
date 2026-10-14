import Foundation
import GuavaUIRuntime

/// Keyboard destinations are transient; only activation writes the selection.
enum CalendarNavigation {
    case days(Int)
    case month(Int)
    case firstDay
    case lastDay

    init?(scancode: UInt32) {
        switch scancode {
        case Scancode.arrowLeft: self = .days(-1)
        case Scancode.arrowRight: self = .days(1)
        case Scancode.arrowUp: self = .days(-7)
        case Scancode.arrowDown: self = .days(7)
        case Scancode.home: self = .firstDay
        case Scancode.end: self = .lastDay
        case Scancode.pageUp: self = .month(-1)
        case Scancode.pageDown: self = .month(1)
        default: return nil
        }
    }

    func destination(from date: Date, calendar: Foundation.Calendar, availability: DateAvailability) -> Date? {
        switch self {
        case .days(let count):
            return CalendarGrid.move(date, days: count, calendar: calendar, availability: availability)
        case .firstDay, .lastDay:
            guard let interval = calendar.dateInterval(of: .month, for: date) else { return nil }
            let direction = self.isFirstDay ? 1 : -1
            let start = direction == 1 ? interval.start
                : calendar.date(byAdding: .day, value: -1, to: interval.end)
            guard let start else { return nil }
            return firstAvailable(from: start, direction: direction, within: interval,
                                  calendar: calendar, availability: availability)
        case .month(let count):
            guard let target = calendar.date(byAdding: .month, value: count, to: date),
                  let interval = calendar.dateInterval(of: .month, for: target) else { return nil }
            let direction = count > 0 ? 1 : -1
            return firstAvailable(from: target, direction: direction, within: interval,
                                  calendar: calendar, availability: availability)
                ?? firstAvailable(from: target, direction: -direction, within: interval,
                                  calendar: calendar, availability: availability)
        }
    }

    private var isFirstDay: Bool {
        if case .firstDay = self { return true }
        return false
    }

    private func firstAvailable(from date: Date, direction: Int, within interval: DateInterval,
                                calendar: Foundation.Calendar, availability: DateAvailability) -> Date? {
        var candidate = calendar.startOfDay(for: date)
        while candidate >= interval.start && candidate < interval.end {
            if availability.contains(candidate, calendar: calendar) { return candidate }
            guard let next = calendar.date(byAdding: .day, value: direction, to: candidate), next != candidate else { return nil }
            candidate = next
        }
        return nil
    }
}
