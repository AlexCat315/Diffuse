import Foundation
import GuavaUIRuntime

public struct CalendarPresentation {
    public var cellSize: Float = 34
    public var numberOfMonths = 1
    public var isEnabled = true
    public init() {}
    mutating func validate() { cellSize = cellSize.isFinite ? max(26, cellSize) : 34; numberOfMonths = min(12, max(1, numberOfMonths)) }
}
public struct CalendarOptions {
    public var calendar = Foundation.Calendar.current
    public var locale = Locale.current
    public var availability = DateAvailability()
    public var presentation = CalendarPresentation()
    public var visibleMonth: Binding<Date>?
    public var today = Date()
    public init() {}
}
private struct CalendarSession {
    var month: Date
    var focusedDay: Date
    var focusRequest = 0
}

/// Caller-owned selection, with transient month browsing and one focusable day per grid.
public struct CalendarView: View {
    public let selection: Binding<Date?>
    public var options = CalendarOptions()
    @State private var session: CalendarSession
    public init(selection: Binding<Date?>, configure: (inout CalendarOptions) -> Void = { _ in }) {
        self.selection = selection; configure(&options); options.presentation.validate()
        options.calendar.firstWeekday = min(7, max(1, options.calendar.firstWeekday))
        let initial = selection.wrappedValue ?? options.today
        _session = State(wrappedValue: CalendarSession(month: CalendarGrid.monthStart(initial, calendar: options.calendar), focusedDay: options.calendar.startOfDay(for: initial)))
    }
    public var body: some View {
        SurfaceReader { surface in
            let cellSize = max(options.presentation.cellSize, surface.input.contains(.touch) ? surface.minimumControlExtent : 0)
            ScrollView(.horizontal, scrollbarGutter: .stable) {
            CalendarKeyHost(onNavigate: navigate) {
                Box(direction: .row, alignItems: .flexStart, wrap: .wrap, spacing: 16) {
                    for index in 0..<options.presentation.numberOfMonths {
                        AnyView(monthView(options.calendar.date(byAdding: .month, value: index, to: month) ?? month, index: index, cellSize: cellSize))
                    }
                }
            }.accessibility { $0.role = .group; $0.label = "Calendar" }
            }.flex(0, shrink: 1).debugName("calendar-scroll")
        }
    }
    private var month: Date { options.visibleMonth?.wrappedValue ?? session.month }
    private func monthView(_ date: Date, index: Int, cellSize: Float) -> some View {
        let days = CalendarGrid.days(in: date, calendar: options.calendar)
        let formatter = DateFormatter(); formatter.calendar = options.calendar; formatter.timeZone = options.calendar.timeZone
        formatter.locale = options.locale; formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        let symbols = formatter.veryShortStandaloneWeekdaySymbols ?? ["S", "M", "T", "W", "T", "F", "S"]
        let monthDays = days.filter { options.calendar.isDate($0, equalTo: date, toGranularity: .month) && isEnabled($0) }
        let tabDay = monthDays.first(where: { options.calendar.isDate($0, inSameDayAs: session.focusedDay) }) ?? monthDays.first
        return Box(direction: .column, alignItems: .stretch, spacing: 6) {
            Row(alignment: .center, spacing: 4) {
                Button(icon: .resource(UIIcons.Navigation.chevronLeft), size: 12, isEnabled: options.presentation.isEnabled && index == 0) { browse(-1) }.buttonStyle(.ghost).accessibilityLabel("Previous month")
                Text(formatter.string(from: date)).font(.bodyStrong).flex(1).padding(horizontal: 4)
                Button(icon: .resource(UIIcons.Navigation.chevronRight), size: 12, isEnabled: options.presentation.isEnabled && index == options.presentation.numberOfMonths - 1) { browse(1) }.buttonStyle(.ghost).accessibilityLabel("Next month")
            }
            Row(alignment: .center, spacing: 2) {
                for weekday in 0..<7 {
                    AnyView(Text(symbols[(weekday + options.calendar.firstWeekday - 1) % 7]).font(.caption).foregroundColor(.onSurfaceMuted)
                        .frame(width: cellSize, height: 24).accessibilityHidden())
                }
            }
            for week in 0..<6 {
                AnyView(Row(alignment: .center, spacing: 2) {
                    for day in days.dropFirst(week * 7).prefix(7) {
                        AnyView(dayView(day, currentMonth: date, tabDay: tabDay, cellSize: cellSize))
                    }
                })
            }
        }.padding(10).frame(minWidth: cellSize * 7 + 32)
            .background(.surface).cornerRadius(.controlRadius).border(.border, width: 1)
    }
    private func dayView(_ day: Date, currentMonth: Date, tabDay: Date?, cellSize: Float) -> some View {
        let inMonth = options.calendar.isDate(day, equalTo: currentMonth, toGranularity: .month)
        let selected = selection.wrappedValue.map { options.calendar.isDate(day, inSameDayAs: $0) } ?? false
        let formatter = DateFormatter(); formatter.dateStyle = .full; formatter.calendar = options.calendar
        formatter.timeZone = options.calendar.timeZone; formatter.locale = options.locale
        return Button(String(options.calendar.component(.day, from: day)), isEnabled: inMonth && isEnabled(day), isSelected: selected) {
            selection.wrappedValue = options.calendar.startOfDay(for: day); session.focusedDay = day
        }.buttonStyle(CalendarDayStyle(cellSize: cellSize, isCurrentMonth: inMonth, isToday: options.calendar.isDate(day, inSameDayAs: options.today)))
            .frame(width: cellSize, height: cellSize).flex(0, shrink: 0)
            .modifier(CalendarDayModifier(day: day, isTabStop: tabDay == day))
            .accessibility { $0.role = .button; $0.label = formatter.string(from: day); $0.state.isSelected = selected }
            .focusRequest(session.focusRequest > 0 && session.focusedDay == day && inMonth && isEnabled(day)
                ? AnyHashable(session.focusRequest) : nil)
            .id(day)
    }
    private func isEnabled(_ day: Date) -> Bool { options.presentation.isEnabled && options.availability.contains(day, calendar: options.calendar) }
    private func browse(_ value: Int) {
        guard let next = options.calendar.date(byAdding: .month, value: value, to: month) else { return }
        if let binding = options.visibleMonth { binding.wrappedValue = next } else { session.month = next }
    }
    private func navigate(_ date: Date, _ code: UInt32) -> Bool {
        guard options.presentation.isEnabled, let navigation = CalendarNavigation(scancode: code) else { return false }
        guard let next = navigation.destination(from: date, calendar: options.calendar,
                                               availability: options.availability) else { return true }
        session.focusedDay = next; session.focusRequest += 1
        reveal(next)
        return true
    }

    private func reveal(_ day: Date) {
        let calendar = options.calendar
        let first = CalendarGrid.monthStart(month, calendar: calendar)
        guard let end = calendar.date(byAdding: .month, value: options.presentation.numberOfMonths, to: first),
              day < first || day >= end else { return }
        let targetMonth = CalendarGrid.monthStart(day, calendar: calendar)
        let next = day < first ? targetMonth
            : calendar.date(byAdding: .month, value: 1 - options.presentation.numberOfMonths, to: targetMonth) ?? targetMonth
        if let binding = options.visibleMonth { binding.wrappedValue = next }
        else { session.month = next }
    }
}
struct CalendarDayModifier: ViewModifier {
    let day: Date
    let isTabStop: Bool
    func apply(node: Node) {
        node.attachments["calendar.day"] = day
        node.isTabStop = isTabStop && node.isFocusable
        if !node.isFocusable, FocusChainHolder.current?.focused === node { FocusChainHolder.current?.clear() }
    }
}
struct CalendarKeyHost<Content: View>: _PrimitiveView {
    let onNavigate: (Date, UInt32) -> Bool
    let content: Content
    init(onNavigate: @escaping (Date, UInt32) -> Bool, @ViewBuilder content: () -> Content) { self.onNavigate = onNavigate; self.content = content() }
    func _makeNode() -> Node { let node = Node(); node.isHitTestable = false; return node }
    func _makeLayoutNode() -> LayoutNode? { nil }
    func _updateNode(_ node: Node) {
        InteractionRegistryHolder.current?.setKey(node) { event, phase in
            guard phase == .bubble, event.modifiers.isEmpty,
                  let date = FocusChainHolder.current?.focused?.attachments["calendar.day"] as? Date else { return .ignored }
            return onNavigate(date, event.scancode) ? .handled : .ignored
        }
    }
    var _children: [any View] { [content] }
}
struct CalendarDayStyle: ButtonStyle {
    let cellSize: Float
    let isCurrentMonth: Bool
    let isToday: Bool
    func makeBody(configuration c: ButtonStyleConfiguration) -> some View {
        Box(direction: .row, alignItems: .center, justifyContent: .center) { AnyView(c.label).font(.label) }
            .frame(width: cellSize, height: cellSize).background(c.isSelected ? c.theme.colors.accent : c.isHovered ? c.theme.colors.stateLayerHover : .clear)
            .foregroundColor(c.isSelected ? c.theme.colors.onAccent : c.isEnabled ? c.theme.colors.onSurface : c.theme.colors.onSurfaceMuted)
            .opacity(isCurrentMonth ? 1 : 0.35).cornerRadius(cellSize / 2)
            .border(c.isFocused ? c.theme.colors.focusRing : isToday ? c.theme.colors.accent : .clear, width: c.isFocused ? 2 : isToday ? 1 : 0)
    }
}
