import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Calendar month keyboard navigation", .serialized)
struct CalendarKeyboardNavigationTests: GuavaUIComposeSerializedSuite {
    private struct Harness: View {
        @State var selection: Date?
        @State var visibleMonth: Date
        @State var isEnabled = true
        let calendar: Foundation.Calendar
        let availability: DateAvailability
        let months: Int
        let width: Float
        init(_ date: Date, calendar: Foundation.Calendar, availability: DateAvailability = DateAvailability(),
             months: Int = 1, width: Float = 390) {
            _selection = State(wrappedValue: date)
            _visibleMonth = State(wrappedValue: CalendarGrid.monthStart(date, calendar: calendar))
            self.calendar = calendar; self.availability = availability; self.months = months; self.width = width
        }
        var body: some View {
            var surface = UIEnvironment()
            surface.viewport.width = width
            surface.input = width == 390 ? [.touch, .keyboard]
                : width == 720 ? [.touch, .pointer, .keyboard] : [.pointer, .keyboard]
            return CalendarView(selection: $selection) {
                $0.calendar = calendar; $0.locale = Locale(identifier: "en_US_POSIX")
                $0.availability = availability; $0.visibleMonth = $visibleMonth
                $0.presentation.numberOfMonths = months; $0.presentation.isEnabled = isEnabled
            }.surfaceEnvironment(surface)
        }
    }

    private func calendar(_ zone: String = "UTC") -> Foundation.Calendar {
        var calendar = Foundation.Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        calendar.firstWeekday = 2
        return calendar
    }
    private func date(_ year: Int, _ month: Int, _ day: Int, in calendar: Foundation.Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }
    private func nodes(_ root: Node) -> [Node] { [root] + root.children.flatMap(nodes) }
    private func day(_ date: Date, in graph: ViewGraph) throws -> Node {
        var match: Node?
        for node in nodes(graph.tree.root!) {
            if node.attachments["calendar.day"] as? Date == date, node.isFocusable { match = node; break }
        }
        return try #require(match)
    }
    private func settle(_ graph: ViewGraph, width: Float = 720) {
        for _ in 0..<4 { graph.recomposer.commitAll(); graph.computeLayout(width: width, height: 900) }
    }
    private func key(_ code: UInt32, graph: ViewGraph, dispatcher: EventDispatcher,
                     width: Float = 720, modifiers: KeyModifiers = []) {
        dispatcher.dispatch(.keyDown(KeyEvent(scancode: code, keycode: 0, modifiers: modifiers, isRepeat: false)))
        settle(graph, width: width)
    }
    private func scene(_ work: (ViewGraph, PlatformInputContext, EventDispatcher, AnimatorScheduler) throws -> Void) rethrows {
        try GlobalTestLock.locked {
            let previous = TextEnvironmentHolder.current
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = previous }
            let context = PlatformInputContext(), portals = PortalStore(), scheduler = AnimatorScheduler()
            context.addScopedAmbient(PortalStoreAmbient(portals))
            try context.withCurrent { try AnimatorScheduler.$current.withValue(scheduler) {
                let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                let dispatcher = EventDispatcher(tree: graph.tree, interactions: context.interactions,
                    capture: context.pointerCapture, focusChain: context.focusChain)
                defer { graph.install(root: EmptyView()); scheduler.tick(deltaTime: 1); graph.recomposer.commitAll() }
                try work(graph, context, dispatcher, scheduler)
            } }
        }
    }

    @Test("Month jumps clamp day numbers and cross leap years, year boundaries and DST")
    func monthArithmetic() throws {
        let calendar = calendar("America/New_York")
        for (start, code, expected): ((Int, Int, Int), UInt32, (Int, Int, Int)) in [
            ((2024, 1, 31), Scancode.pageDown, (2024, 2, 29)),
            ((2023, 3, 31), Scancode.pageUp, (2023, 2, 28)),
            ((2024, 1, 31), Scancode.pageUp, (2023, 12, 31)),
            ((2024, 12, 31), Scancode.pageDown, (2025, 1, 31)),
            ((2024, 3, 15), Scancode.home, (2024, 3, 1)),
            ((2024, 3, 15), Scancode.end, (2024, 3, 31)),
            ((2024, 2, 15), Scancode.pageDown, (2024, 3, 15))
        ] {
            let command = try #require(CalendarNavigation(scancode: code))
            #expect(command.destination(from: date(start.0, start.1, start.2, in: calendar),
                calendar: calendar, availability: DateAvailability()) == date(expected.0, expected.1, expected.2, in: calendar))
        }
        let february = date(2024, 2, 15, in: calendar), march = date(2024, 3, 15, in: calendar)
        #expect(march.timeIntervalSince(february) == 29 * 24 * 3_600 - 3_600)
        #expect(CalendarNavigation(scancode: Scancode.a) == nil)
    }

    @Test("Month boundaries and jumps skip unavailable days within the destination month")
    func availability() throws {
        let calendar = calendar()
        var availability = DateAvailability()
        availability.minimum = date(2024, 2, 8, in: calendar)
        availability.maximum = date(2024, 2, 20, in: calendar)
        availability.isEnabled = { ![8, 9, 20].contains(calendar.component(.day, from: $0)) }
        for (start, command, expected): ((Int, Int, Int), CalendarNavigation, Int) in [
            ((2024, 2, 15), .firstDay, 10), ((2024, 2, 15), .lastDay, 19),
            ((2024, 1, 31), .month(1), 19), ((2024, 3, 1), .month(-1), 10)
        ] {
            #expect(command.destination(from: date(start.0, start.1, start.2, in: calendar),
                calendar: calendar, availability: availability) == date(2024, 2, expected, in: calendar))
        }
        availability.minimum = nil; availability.maximum = nil
        availability.isEnabled = { [10, 16].contains(calendar.component(.day, from: $0)) }
        #expect(CalendarNavigation.month(1).destination(from: date(2024, 1, 15, in: calendar),
            calendar: calendar, availability: availability) == date(2024, 2, 16, in: calendar))
        #expect(CalendarNavigation.month(-1).destination(from: date(2024, 3, 15, in: calendar),
            calendar: calendar, availability: availability) == date(2024, 2, 10, in: calendar))
        availability.isEnabled = { _ in false }
        #expect(CalendarNavigation.month(1).destination(from: date(2024, 1, 15, in: calendar),
            calendar: calendar, availability: availability) == nil)
        #expect(CalendarNavigation.firstDay.destination(from: date(2024, 1, 15, in: calendar),
            calendar: calendar, availability: availability) == nil)
    }

    @Test("Actual focus follows month commands while selection waits for Enter", arguments: [Float(390), 720, 1280])
    func keyboardFocus(width: Float) throws {
        try scene { graph, context, dispatcher, _ in
            let calendar = calendar(), initial = date(2024, 1, 31, in: calendar)
            let harness = Harness(initial, calendar: calendar, width: width)
            graph.install(root: harness); settle(graph, width: width)
            context.focusChain.focus(try day(initial, in: graph))
            for (code, expected): (UInt32, (Int, Int)) in [
                (Scancode.pageDown, (2, 29)), (Scancode.home, (2, 1)),
                (Scancode.end, (2, 29)), (Scancode.pageUp, (1, 29)), (Scancode.pageDown, (2, 29))
            ] {
                key(code, graph: graph, dispatcher: dispatcher, width: width)
                let target = date(2024, expected.0, expected.1, in: calendar)
                #expect(context.focusChain.focused === (try day(target, in: graph)))
                #expect(harness.selection == initial)
                #expect(harness.visibleMonth == date(2024, expected.0, 1, in: calendar))
                #expect(context.focusChain.focused?.accessibility?.role == .button)
                #expect(context.focusChain.focused?.accessibility?.state.isSelected == false)
                #expect(!graph.recomposer.hasPending)
            }
            key(Scancode.return, graph: graph, dispatcher: dispatcher, width: width)
            #expect(harness.selection == date(2024, 2, 29, in: calendar))
            #expect(context.focusChain.focused?.accessibility?.state.isSelected == true)
            if width < 1_000 { #expect(context.focusChain.focused?.frame.height == 44) }
            harness.isEnabled = false; settle(graph, width: width)
            #expect(context.focusChain.focused == nil)
            key(Scancode.pageDown, graph: graph, dispatcher: dispatcher, width: width)
            #expect(harness.visibleMonth == date(2024, 2, 1, in: calendar))
        }
    }

    @Test("Empty target months, minimum bounds and modified commands leave focus and visible month intact")
    func unavailableMonths() throws {
        try scene { graph, context, dispatcher, _ in
            let calendar = calendar(), initial = date(2024, 1, 15, in: calendar)
            var availability = DateAvailability()
            availability.minimum = date(2024, 1, 1, in: calendar)
            availability.isEnabled = { calendar.component(.month, from: $0) != 2 }
            let harness = Harness(initial, calendar: calendar, availability: availability)
            graph.install(root: harness); settle(graph)
            let original = try day(initial, in: graph)
            context.focusChain.focus(original)
            key(Scancode.pageDown, graph: graph, dispatcher: dispatcher)
            key(Scancode.pageUp, graph: graph, dispatcher: dispatcher)
            key(Scancode.pageDown, graph: graph, dispatcher: dispatcher, modifiers: .ctrl)
            #expect(context.focusChain.focused === original)
            #expect(harness.visibleMonth == date(2024, 1, 1, in: calendar) && harness.selection == initial)
        }
    }

    @Test("Multiple displayed months keep their window until a keyboard destination leaves it")
    func monthWindow() throws {
        try scene { graph, context, dispatcher, _ in
            let calendar = calendar(), initial = date(2024, 1, 15, in: calendar)
            let harness = Harness(initial, calendar: calendar, months: 2, width: 720)
            graph.install(root: harness); settle(graph)
            let january = try day(initial, in: graph)
            context.focusChain.focus(january)
            key(Scancode.pageDown, graph: graph, dispatcher: dispatcher)
            #expect(harness.visibleMonth == date(2024, 1, 1, in: calendar))
            #expect(context.focusChain.focused === (try day(date(2024, 2, 15, in: calendar), in: graph)))
            #expect(try day(initial, in: graph) === january)
            key(Scancode.pageDown, graph: graph, dispatcher: dispatcher)
            #expect(harness.visibleMonth == date(2024, 2, 1, in: calendar))
            #expect(context.focusChain.focused === (try day(date(2024, 3, 15, in: calendar), in: graph)))
            key(Scancode.pageUp, graph: graph, dispatcher: dispatcher)
            key(Scancode.pageUp, graph: graph, dispatcher: dispatcher)
            #expect(harness.visibleMonth == date(2024, 1, 1, in: calendar) && harness.selection == initial)
        }
    }

    @Test("DatePicker exposes month navigation without committing or dismissing until Enter")
    func datePicker() throws {
        try scene { graph, context, dispatcher, scheduler in
            let calendar = calendar(), initial = date(2024, 1, 31, in: calendar)
            var selection: Date? = initial
            graph.install(root: LayerRoot {
                DatePicker(selection: Binding(get: { selection }, set: { selection = $0 })) {
                    $0.calendar.calendar = calendar; $0.calendar.today = initial
                }
            }); settle(graph)
            var trigger: Node?
            for node in nodes(graph.tree.root!) {
                if node.attachments[ButtonHost.markerKey] as? Bool == true { trigger = node; break }
            }
            let button = try #require(trigger)
            context.focusChain.focus(button)
            button.accessibilityActions.activate?(); settle(graph)
            scheduler.tick(deltaTime: 1); settle(graph)
            context.focusChain.focus(try day(initial, in: graph))
            key(Scancode.pageDown, graph: graph, dispatcher: dispatcher)
            let target = date(2024, 2, 29, in: calendar)
            #expect(context.focusChain.focused === (try day(target, in: graph)))
            #expect(selection == initial && PortalStoreHolder.current.entries.count == 1)
            key(Scancode.return, graph: graph, dispatcher: dispatcher)
            scheduler.tick(deltaTime: 1); settle(graph)
            #expect(selection == target && PortalStoreHolder.current.entries.isEmpty)
            #expect(context.focusChain.focused === button)
        }
    }
}
