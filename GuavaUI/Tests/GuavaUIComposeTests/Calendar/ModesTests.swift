import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

/// Week, month and year granularity, and drilling between day, month and
/// year panels.
@Suite("Calendar granularity and panels", .serialized)
struct CalendarModesTests: GuavaUIComposeSerializedSuite {
    private final class Store { var selection: Date? }

    private func calendar() -> Foundation.Calendar {
        var calendar = Foundation.Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }
    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar().date(from: DateComponents(year: year, month: month, day: day))!
    }
    private func nodes(_ root: Node) -> [Node] { [root] + root.children.flatMap(nodes) }
    private func hasText(_ node: Node) -> Bool { node.layoutNode?.textInputs != nil }
    private func buttons(_ graph: ViewGraph) -> [Node] {
        nodes(graph.tree.root!).filter { $0.accessibility?.role == .button && $0.accessibility?.isHidden != true }
    }
    private func button(_ label: String, in graph: ViewGraph) throws -> Node {
        try #require(buttons(graph).first { $0.accessibility?.label == label }, "no \(label)")
    }
    private func settle(_ graph: ViewGraph) {
        for _ in 0..<4 { graph.recomposer.commitAll(); graph.computeLayout(width: 720, height: 900) }
    }

    private func render(_ store: Store, granularity: CalendarGranularity, availability: DateAvailability = DateAvailability(),
                        _ test: (ViewGraph) throws -> Void) throws {
        try GlobalTestLock.locked {
            let old = TextEnvironmentHolder.current; TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = old }
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            let calendar = calendar()
            graph.install(root: CalendarView(selection: Binding(get: { store.selection }, set: { store.selection = $0 })) {
                $0.calendar = calendar; $0.locale = Locale(identifier: "en_US_POSIX")
                $0.granularity = granularity; $0.availability = availability
                $0.today = self.date(2024, 3, 13)
            })
            settle(graph)
            try test(graph)
            graph.install(root: EmptyView())
        }
    }

    @Test("Week rows are single buttons that select the week's first day")
    func weekSelection() throws {
        let store = Store(); store.selection = date(2024, 3, 13)
        try render(store, granularity: .week) { graph in
            let weeks = buttons(graph).filter { $0.accessibility?.label.hasPrefix("Week ") == true }
            #expect(weeks.count == 6)
            let selected = try #require(weeks.first { $0.accessibility?.state.isSelected == true })
            #expect(selected.accessibility?.label.hasPrefix("Week 11,") == true, "\(selected.accessibility?.label ?? "")")
            let next = try #require(weeks.first { $0.accessibility?.label.hasPrefix("Week 12,") == true })
            next.accessibilityActions.activate?(); settle(graph)
            #expect(store.selection == date(2024, 3, 18))
        }
    }

    @Test("Week numbers are centred in the row band, and today keeps the row's type size")
    func weekRowAlignment() throws {
        let store = Store(); store.selection = date(2024, 3, 11)
        try render(store, granularity: .week) { graph in
            let row = try #require(buttons(graph).first { $0.accessibility?.state.isSelected == true })
            let texts = nodes(row).filter(hasText)
            #expect(texts.count == 8)
            // Text draws from the top of its box, so a number stretched to the
            // row height would sit high even with a centred frame.
            for text in texts {
                #expect(text.absoluteFrame.height < row.absoluteFrame.height - 8)
                #expect(abs(text.absoluteFrame.midY - row.absoluteFrame.midY) < 1, "\(text.layoutNode?.textInputs?.text ?? "") at \(text.absoluteFrame) in \(row.absoluteFrame)")
            }
            // Columns line up with the header: Wk over week numbers, weekdays over days.
            let header = nodes(graph.tree.root!).filter(hasText).filter { $0.absoluteFrame.height == 24 }
                .map(\.absoluteFrame.midX).sorted()
            let columns = texts.map(\.absoluteFrame.midX).sorted()
            #expect(header.count == 8 && columns.count == 8)
            #expect(zip(header, columns).allSatisfy { abs($0 - $1) < 1 }, "header \(header) vs row \(columns)")
            let heights = Dictionary(texts.map { ($0.layoutNode?.textInputs?.text ?? "", $0.absoluteFrame.height) }) { first, _ in first }
            #expect(heights["13"] != nil && heights["13"] == heights["12"], "today 13 vs 12: \(heights)")
        }
    }

    @Test("Month granularity opens on a year of months and selects a month start")
    func monthSelection() throws {
        let store = Store(); store.selection = date(2024, 3, 20)
        var availability = DateAvailability(); availability.minimum = date(2024, 3, 10)
        try render(store, granularity: .month, availability: availability) { graph in
            let march = try button("March 2024", in: graph)
            #expect(march.accessibility?.state.isSelected == true)
            #expect(try button("February 2024", in: graph).accessibility?.state.isEnabled == false, "no available day")
            try button("June 2024", in: graph).accessibilityActions.activate?(); settle(graph)
            #expect(store.selection == date(2024, 6, 1))
        }
    }

    @Test("Year granularity pages twelve aligned years and selects a year start")
    func yearSelection() throws {
        let store = Store(); store.selection = date(2024, 7, 4)
        try render(store, granularity: .year) { graph in
            #expect(try button("2016", in: graph).isFocusable)
            #expect(try button("2027", in: graph).isFocusable)
            #expect(buttons(graph).allSatisfy { $0.accessibility?.label != "2015" && $0.accessibility?.label != "2028" })
            try button("Next years", in: graph).accessibilityActions.activate?(); settle(graph)
            try button("2031", in: graph).accessibilityActions.activate?(); settle(graph)
            #expect(store.selection == date(2031, 1, 1))
        }
    }

    @Test("The title drills up to months and years; a pick drills back down without selecting")
    func drilling() throws {
        let store = Store(); store.selection = date(2024, 3, 13)
        try render(store, granularity: .day) { graph in
            try button("March 2024, show months", in: graph).accessibilityActions.activate?(); settle(graph)
            try button("2024, show years", in: graph).accessibilityActions.activate?(); settle(graph)
            #expect(buttons(graph).allSatisfy { $0.accessibility?.label.hasSuffix("show years") != true }, "years is the top")
            try button("2026", in: graph).accessibilityActions.activate?(); settle(graph)
            try button("September 2026", in: graph).accessibilityActions.activate?(); settle(graph)
            #expect(try button("September 2026, show months", in: graph).isFocusable)
            #expect(store.selection == date(2024, 3, 13), "browsing never writes the selection")
            try button("Tuesday, September 15, 2026", in: graph).accessibilityActions.activate?(); settle(graph)
            #expect(store.selection == date(2026, 9, 15))
        }
    }

    @Test("Keys move by one cell, a row, a page, or to the page's ends in every panel")
    func panelNavigation() throws {
        let calendar = calendar(), all = DateAvailability()
        func move(_ code: UInt32, from start: Date, _ panel: CalendarPanel, _ granularity: CalendarGranularity) throws -> Date? {
            let cells = CalendarCells(panel: panel, granularity: granularity)
            return try #require(CalendarNavigation(scancode: code, columns: cells.columns))
                .destination(from: start, cells: cells, calendar: calendar, availability: all)
        }
        let march = date(2024, 3, 1)
        #expect(try move(Scancode.arrowRight, from: march, .months, .month) == date(2024, 4, 1))
        #expect(try move(Scancode.arrowDown, from: march, .months, .month) == date(2024, 6, 1))
        #expect(try move(Scancode.pageDown, from: march, .months, .month) == date(2025, 3, 1))
        #expect(try move(Scancode.home, from: march, .months, .month) == date(2024, 1, 1))
        #expect(try move(Scancode.end, from: date(2024, 1, 1), .years, .year) == date(2027, 1, 1))
        #expect(try move(Scancode.arrowUp, from: date(2024, 1, 1), .years, .year) == date(2021, 1, 1))
        // Week rows: Down is one week; Home is the first week touching March.
        #expect(try move(Scancode.arrowDown, from: date(2024, 3, 11), .days, .week) == date(2024, 3, 18))
        #expect(try move(Scancode.home, from: date(2024, 3, 11), .days, .week) == date(2024, 2, 26))
        #expect(try move(Scancode.end, from: date(2024, 3, 11), .days, .week) == date(2024, 3, 25))
    }

    @Test("Period labels name the week, month or year")
    func labels() {
        let calendar = calendar(), locale = Locale(identifier: "en_US_POSIX")
        #expect(CalendarGranularity.week.label(for: date(2024, 3, 18), calendar: calendar, locale: locale) == "Week 12, 2024")
        #expect(CalendarGranularity.month.label(for: date(2024, 3, 1), calendar: calendar, locale: locale) == "March 2024")
        #expect(CalendarGranularity.year.label(for: date(2024, 1, 1), calendar: calendar, locale: locale) == "2024")
    }
}
