import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Date range presets and maximum length", .serialized)
@MainActor
struct DateRangeRulesTests: GuavaUIComposeSerializedSuite {
    private struct RangeHarness: View {
        let calendar: Calendar
        let today: Date
        let record: (ClosedRange<Date>?) -> Void
        @State var selection: ClosedRange<Date>?
        var body: some View {
            var rules = DateRangeRules()
            rules.maximumDays = 5
            rules.presets = [.lastDays(3), .lastDays(30)]
            return DateRangeCalendar(selection: Binding(get: { selection }, set: { selection = $0; record($0) }), rules: rules) {
                $0.calendar = calendar; $0.locale = Locale(identifier: "en_US_POSIX"); $0.today = today
            }.frame(width: 460, height: 560)
        }
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 1
        return calendar
    }
    private func date(_ day: Int, month: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day))!
    }

    @Test("Built-in presets resolve relative to today with start-of-day bounds")
    func presets() throws {
        let today = date(20)
        #expect(DateRangePreset.today().range(today: today, calendar: calendar) == today...today)
        #expect(DateRangePreset.yesterday().range(today: today, calendar: calendar) == date(19)...date(19))
        #expect(DateRangePreset.lastDays(7).range(today: today, calendar: calendar) == date(14)...today)
        #expect(DateRangePreset.thisMonth().range(today: today, calendar: calendar) == date(1)...date(31))
        #expect(DateRangePreset.lastMonth().range(today: today, calendar: calendar) == date(1, month: 9)...date(30, month: 9))
        #expect(DateRangePreset.lastDays(0).id == "last-1-days")
    }

    @Test("Rules count both endpoints and validate the maximum")
    func rules() throws {
        var rules = DateRangeRules(); rules.maximumDays = 0; rules.validate()
        #expect(rules.maximumDays == 1)
        rules.maximumDays = 7
        #expect(DateRangeRules.dayCount(date(1)...date(7), calendar: calendar) == 7)
        #expect(rules.allows(date(1)...date(7), calendar: calendar))
        #expect(!rules.allows(date(1)...date(8), calendar: calendar))
        #expect(rules.canComplete(from: date(10), to: date(4), calendar: calendar))
        #expect(!rules.canComplete(from: date(10), to: date(3), calendar: calendar))
    }

    @Test("A pending start disables days beyond the maximum; presets write the selection")
    func calendarInteraction() throws {
        try InteractiveScene.run(width: 600, height: 700) { scene in
            var selection: ClosedRange<Date>?
            let calendar = calendar, today = date(20)
            scene.install(RangeHarness(calendar: calendar, today: today, record: { selection = $0 }))
            func day(_ value: Int) throws -> Node {
                try #require(scene.first {
                    guard let date = $0.attachments["calendar.day"] as? Date else { return false }
                    return calendar.component(.day, from: date) == value && calendar.component(.month, from: date) == 10
                })
            }
            func isEnabled(_ value: Int) throws -> Bool {
                InteractiveScene.descendants(try day(value)).contains { $0.accessibility?.role == .button && $0.accessibility?.state.isEnabled == true }
            }
            scene.click(try day(10))
            #expect((try isEnabled(14)))
            #expect(!(try isEnabled(15)))
            #expect(!(try isEnabled(5)))
            scene.click(try day(15))
            #expect(selection == date(10)...date(10))
            scene.click(try day(13))
            #expect(selection == date(10)...date(13))

            func preset(_ title: String) throws -> Node {
                try #require(scene.first { $0.attachments[ButtonHost.markerKey] != nil && $0.accessibility?.label == title })
            }
            let short = try preset("Last 3 days"), long = try preset("Last 30 days")
            #expect(long.accessibility?.state.isEnabled == false)
            scene.click(short)
            #expect(selection == date(18)...today)
            #expect(try preset("Last 3 days").accessibility?.state.isSelected == true)
        }
    }
}
