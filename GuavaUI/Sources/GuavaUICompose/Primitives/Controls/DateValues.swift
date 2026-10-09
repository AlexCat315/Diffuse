import Foundation

public struct DateAvailability {
    public var minimum: Date?
    public var maximum: Date?
    public var isEnabled: (Date) -> Bool = { _ in true }
    public init() {}
    public func contains(_ date: Date, calendar: Foundation.Calendar) -> Bool {
        let day = calendar.startOfDay(for: date)
        if let minimum, day < calendar.startOfDay(for: minimum) { return false }
        if let maximum, day > calendar.startOfDay(for: maximum) { return false }
        return isEnabled(day)
    }
}

/// Date arithmetic uses calendar components, so a day is not assumed to be 24 hours.
public enum CalendarGrid {
    public static func monthStart(_ date: Date, calendar: Foundation.Calendar) -> Date {
        calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
    }
    public static func days(in month: Date, calendar: Foundation.Calendar) -> [Date] {
        let start = monthStart(month, calendar: calendar)
        let weekday = calendar.component(.weekday, from: start)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        guard let first = calendar.date(byAdding: .day, value: -leading, to: start) else { return [] }
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: first) }
    }
    public static func move(_ date: Date, days: Int, calendar: Foundation.Calendar, availability: DateAvailability) -> Date? {
        guard days != 0 else { return availability.contains(date, calendar: calendar) ? date : nil }
        var candidate = date
        for _ in 0..<3660 {
            guard let next = calendar.date(byAdding: .day, value: days, to: candidate) else { return nil }
            candidate = next
            if let maximum = availability.maximum, calendar.startOfDay(for: candidate) > calendar.startOfDay(for: maximum), days > 0 { return nil }
            if let minimum = availability.minimum, calendar.startOfDay(for: candidate) < calendar.startOfDay(for: minimum), days < 0 { return nil }
            if availability.contains(candidate, calendar: calendar) { return candidate }
        }
        return nil
    }
}

public struct TimeOfDay: Sendable, Hashable, Comparable, Codable {
    public let hour: Int
    public let minute: Int
    public let second: Int
    public init(hour: Int = 0, minute: Int = 0, second: Int = 0) {
        self.hour = min(23, max(0, hour)); self.minute = min(59, max(0, minute)); self.second = min(59, max(0, second))
    }
    public var seconds: Int { hour * 3600 + minute * 60 + second }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.seconds < rhs.seconds }
    public func formatted(showSeconds: Bool = false) -> String {
        showSeconds ? String(format: "%02d:%02d:%02d", hour, minute, second) : String(format: "%02d:%02d", hour, minute)
    }
    public static func parse(_ text: String, showSeconds: Bool = false) -> Self? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == (showSeconds ? 3 : 2), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let hour = Int(parts[0]), let minute = Int(parts[1]), (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        let second = showSeconds ? Int(parts[2]) : 0
        guard let second, (0...59).contains(second) else { return nil }
        return Self(hour: hour, minute: minute, second: second)
    }
    private enum CodingKeys: String, CodingKey { case hour, minute, second }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(hour: try values.decodeIfPresent(Int.self, forKey: .hour) ?? 0,
                  minute: try values.decodeIfPresent(Int.self, forKey: .minute) ?? 0,
                  second: try values.decodeIfPresent(Int.self, forKey: .second) ?? 0)
    }
}
