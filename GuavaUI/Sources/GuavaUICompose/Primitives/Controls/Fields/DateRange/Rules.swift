import Foundation

/// Shortcut that resolves to a closed day range relative to `today`.
/// Built-in factories cover the common filters; custom presets supply their
/// own resolver. Results are normalized to start-of-day bounds.
public struct DateRangePreset: Identifiable {
    public let id: String
    public var title: String
    private let resolve: (_ today: Date, _ calendar: Calendar) -> ClosedRange<Date>?

    public init(id: String, title: String,
                resolve: @escaping (_ today: Date, _ calendar: Calendar) -> ClosedRange<Date>?) {
        self.id = id; self.title = title; self.resolve = resolve
    }

    /// Normalized range for `today`, or `nil` when the resolver cannot answer.
    public func range(today: Date, calendar: Calendar) -> ClosedRange<Date>? {
        guard let raw = resolve(today, calendar) else { return nil }
        let lower = calendar.startOfDay(for: min(raw.lowerBound, raw.upperBound))
        let upper = calendar.startOfDay(for: max(raw.lowerBound, raw.upperBound))
        return lower...upper
    }

    public static func today(_ title: String = "Today") -> Self {
        Self(id: "today", title: title) { today, _ in today...today }
    }

    public static func yesterday(_ title: String = "Yesterday") -> Self {
        Self(id: "yesterday", title: title) { today, calendar in
            calendar.date(byAdding: .day, value: -1, to: today).map { $0...$0 }
        }
    }

    /// The last `count` days including today.
    public static func lastDays(_ count: Int, title: String? = nil) -> Self {
        let count = max(1, count)
        return Self(id: "last-\(count)-days", title: title ?? "Last \(count) days") { today, calendar in
            calendar.date(byAdding: .day, value: 1 - count, to: today).map { $0...today }
        }
    }

    public static func thisMonth(_ title: String = "This month") -> Self {
        Self(id: "this-month", title: title) { today, calendar in month(containing: today, calendar: calendar) }
    }

    public static func lastMonth(_ title: String = "Last month") -> Self {
        Self(id: "last-month", title: title) { today, calendar in
            calendar.date(byAdding: .month, value: -1, to: today).flatMap { month(containing: $0, calendar: calendar) }
        }
    }

    private static func month(containing day: Date, calendar: Calendar) -> ClosedRange<Date>? {
        guard let interval = calendar.dateInterval(of: .month, for: day),
              let last = calendar.date(byAdding: .day, value: -1, to: interval.end) else { return nil }
        return interval.start...last
    }
}

/// Range-only rules layered on the shared calendar options: shortcut presets
/// and an inclusive maximum length in days.
public struct DateRangeRules {
    public var presets: [DateRangePreset] = []
    /// Longest selectable range, counting both endpoints. `nil` is unlimited.
    public var maximumDays: Int?
    public init() {}

    mutating func validate() { maximumDays = maximumDays.map { max(1, $0) } }

    /// Inclusive day count of a start-of-day range.
    static func dayCount(_ range: ClosedRange<Date>, calendar: Calendar) -> Int {
        (calendar.dateComponents([.day], from: calendar.startOfDay(for: range.lowerBound),
                                 to: calendar.startOfDay(for: range.upperBound)).day ?? 0) + 1
    }

    func allows(_ range: ClosedRange<Date>, calendar: Calendar) -> Bool {
        guard let maximumDays else { return true }
        return Self.dayCount(range, calendar: calendar) <= maximumDays
    }

    /// Whether `day` can complete a range that started at `start`.
    func canComplete(from start: Date, to day: Date, calendar: Calendar) -> Bool {
        allows(min(start, day)...max(start, day), calendar: calendar)
    }
}
