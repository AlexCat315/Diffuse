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
    /// Whether a selection is a day, a week, a month or a year.
    public var granularity: CalendarGranularity = .day
    public var visibleMonth: Binding<Date>?
    public var today = Date()
    public init() {}
}
private struct CalendarSession {
    var month: Date
    /// The roving tab stop: a day, week, month or year start for the panel.
    var focusedDay: Date
    var focusRequest = 0
    var panel: CalendarPanel
}

/// Caller-owned selection, with transient browsing and one focusable cell
/// per grid. The title drills up from days to a year of months to twelve
/// years; picking a cell drills back down to the selection granularity.
public struct CalendarView: View {
    public let selection: Binding<Date?>
    public var options = CalendarOptions()
    @State private var session: CalendarSession
    public init(selection: Binding<Date?>, configure: (inout CalendarOptions) -> Void = { _ in }) {
        self.selection = selection; configure(&options); options.presentation.validate()
        options.calendar.firstWeekday = min(7, max(1, options.calendar.firstWeekday))
        let initial = selection.wrappedValue ?? options.today
        let panel = options.granularity.basePanel
        _session = State(wrappedValue: CalendarSession(
            month: CalendarGrid.monthStart(initial, calendar: options.calendar),
            focusedDay: CalendarCells(panel: panel, granularity: options.granularity).start(initial, calendar: options.calendar),
            panel: panel))
    }

    /// Width of the open calendar for popover hosts.
    static func width(cellSize: Float, options: CalendarOptions) -> Float {
        let months = options.granularity.basePanel == .days ? Float(options.presentation.numberOfMonths) : 1
        return months * (panelWidth(cellSize: cellSize, granularity: options.granularity) + 24)
    }
    private static func panelWidth(cellSize: Float, granularity: CalendarGranularity) -> Float {
        cellSize * 7 + 12 + (granularity == .week ? weekNumberWidth + 2 : 0)
    }
    private static let weekNumberWidth: Float = 24

    public var body: some View {
        SurfaceReader { surface in
            let cellSize = max(options.presentation.cellSize, surface.input.contains(.touch) ? surface.minimumControlExtent : 0)
            ScrollView(.horizontal, scrollbarGutter: .stable) {
            CalendarKeyHost(onNavigate: navigate) {
                if session.panel == .days {
                    Box(direction: .row, alignItems: .flexStart, wrap: .wrap, spacing: 16) {
                        for index in 0..<options.presentation.numberOfMonths {
                            AnyView(monthView(options.calendar.date(byAdding: .month, value: index, to: month) ?? month, index: index, cellSize: cellSize))
                        }
                    }
                } else {
                    periodPanel(cellSize: cellSize)
                }
            }.accessibility { $0.role = .group; $0.label = "Calendar" }
            }.flex(0, shrink: 1).debugName("calendar-scroll")
        }
    }

    private var month: Date { options.visibleMonth?.wrappedValue ?? session.month }
    private var cells: CalendarCells { CalendarCells(panel: session.panel, granularity: options.granularity) }

    // MARK: Header

    private func header(title: String, label: String, previous: String, next: String,
                        canPrevious: Bool, canNext: Bool, step: Int) -> some View {
        Row(alignment: .center, spacing: 4) {
            Button(icon: .resource(UIIcons.Navigation.chevronLeft), size: 12,
                   isEnabled: options.presentation.isEnabled && canPrevious) { browse(-step) }
                .buttonStyle(.ghost).accessibilityLabel(previous)
            if let parent = session.panel.parent {
                Button(isEnabled: options.presentation.isEnabled, tooltip: "Show \(parent == .months ? "months" : "years")",
                       action: { drillUp() }) {
                    Row(alignment: .center, spacing: 4) {
                        Text(title).font(.bodyStrong)
                        Icon(UIIcons.Navigation.chevronDown, size: .small).accessibilityHidden()
                    }.padding(horizontal: 6)
                }.buttonStyle(.ghost).accessibilityLabel(label).frame(height: 32).flex(0, shrink: 1)
                Box {}.flex(1)
            } else {
                Text(title).font(.bodyStrong).padding(horizontal: 12).flex(1)
            }
            Button(icon: .resource(UIIcons.Navigation.chevronRight), size: 12,
                   isEnabled: options.presentation.isEnabled && canNext) { browse(step) }
                .buttonStyle(.ghost).accessibilityLabel(next)
        }
    }

    // MARK: Days

    private func monthView(_ date: Date, index: Int, cellSize: Float) -> some View {
        let days = CalendarGrid.days(in: date, calendar: options.calendar)
        let formatter = formatter("MMMM yyyy")
        let symbols = formatter.veryShortStandaloneWeekdaySymbols ?? ["S", "M", "T", "W", "T", "F", "S"]
        let isWeek = options.granularity == .week
        let tabCell = tabStop(in: date, days: days)
        let title = formatter.string(from: date)
        return Box(direction: .column, alignItems: .stretch, spacing: 6) {
            header(title: title, label: "\(title), show months", previous: "Previous month", next: "Next month",
                   canPrevious: index == 0, canNext: index == options.presentation.numberOfMonths - 1, step: 1)
            Row(alignment: .center, spacing: 2) {
                if isWeek {
                    Text("Wk").font(.caption).foregroundColor(.onSurfaceMuted)
                        .frame(width: Self.weekNumberWidth, height: 24).accessibilityHidden()
                }
                for weekday in 0..<7 {
                    AnyView(Text(symbols[(weekday + options.calendar.firstWeekday - 1) % 7]).font(.caption).foregroundColor(.onSurfaceMuted)
                        .frame(width: cellSize, height: 24).accessibilityHidden())
                }
            }
            for week in 0..<6 {
                let row = Array(days.dropFirst(week * 7).prefix(7))
                if isWeek {
                    AnyView(weekView(row, currentMonth: date, tabCell: tabCell, cellSize: cellSize))
                } else {
                    AnyView(Row(alignment: .center, spacing: 2) {
                        for day in row {
                            AnyView(dayView(day, currentMonth: date, tabDay: tabCell, cellSize: cellSize))
                        }
                    })
                }
            }
        }.padding(10).frame(minWidth: Self.panelWidth(cellSize: cellSize, granularity: options.granularity) + 20)
            .background(.surface).cornerRadius(.controlRadius).border(.border, width: 1)
    }

    /// The focused cell when it is in this month, else the first available one.
    private func tabStop(in month: Date, days: [Date]) -> Date? {
        let cells = self.cells
        let candidates = Set(days.filter { options.calendar.isDate($0, equalTo: month, toGranularity: .month) }
            .map { cells.start($0, calendar: options.calendar) })
            .filter { cells.isAvailable($0, calendar: options.calendar, availability: options.availability) && options.presentation.isEnabled }
            .sorted()
        let focused = cells.start(session.focusedDay, calendar: options.calendar)
        return candidates.contains(focused) ? focused : candidates.first
    }

    private func dayView(_ day: Date, currentMonth: Date, tabDay: Date?, cellSize: Float) -> some View {
        let inMonth = options.calendar.isDate(day, equalTo: currentMonth, toGranularity: .month)
        let selected = isSelected(day)
        let formatter = DateFormatter(); formatter.dateStyle = .full; formatter.calendar = options.calendar
        formatter.timeZone = options.calendar.timeZone; formatter.locale = options.locale
        return Button(String(options.calendar.component(.day, from: day)), isEnabled: inMonth && isEnabled(day), isSelected: selected) {
            choose(day)
        }.buttonStyle(CalendarCellStyle(width: cellSize, height: cellSize, isCurrentMonth: inMonth,
                                        isToday: options.calendar.isDate(day, inSameDayAs: options.today)))
            .frame(width: cellSize, height: cellSize).flex(0, shrink: 0)
            .modifier(CalendarDayModifier(day: day, isTabStop: tabDay == day)).focusRequest(focusToken(day, isFocusable: inMonth && isEnabled(day)))
            .accessibility { $0.role = .button; $0.label = formatter.string(from: day); $0.state.isSelected = selected }
            .id(day)
    }

    /// Week granularity: each row is one button, so hover, selection and
    /// focus cover the whole week, led by its week number.
    private func weekView(_ days: [Date], currentMonth: Date, tabCell: Date?, cellSize: Float) -> some View {
        let calendar = options.calendar
        let start = cells.start(days[0], calendar: calendar)
        let inMonth = days.contains { calendar.isDate($0, equalTo: currentMonth, toGranularity: .month) }
        let available = inMonth && cells.isAvailable(start, calendar: calendar, availability: options.availability)
            && options.presentation.isEnabled
        let selected = isSelected(start)
        let range = DateIntervalFormatter(); range.calendar = calendar; range.timeZone = calendar.timeZone
        range.locale = options.locale; range.dateStyle = .medium; range.timeStyle = .none
        let label = "Week \(calendar.component(.weekOfYear, from: start)), " + range.string(from: days[0], to: days[6])
        return Button(isEnabled: available, isSelected: selected, action: { choose(start) }) {
            Row(alignment: .center, spacing: 2) {
                // Each number sits centred in its own cell box: a Text given
                // the full cell height would draw at the top of the row.
                Box(direction: .row, alignItems: .center, justifyContent: .center) {
                    Text(String(calendar.component(.weekOfYear, from: start))).font(.caption).opacity(0.75)
                }.frame(width: Self.weekNumberWidth, height: cellSize)
                for day in days {
                    // The ring is inset inside a full cell: padding on a fixed frame
                    // shrinks inward (border-box), so it cannot pad the cell out.
                    AnyView(Box(direction: .row, alignItems: .center, justifyContent: .center) {
                        Box(direction: .row, alignItems: .center, justifyContent: .center) {
                            Text(String(calendar.component(.day, from: day))).font(.label)
                        }
                        .frame(width: cellSize - 6, height: cellSize - 6).cornerRadius((cellSize - 6) / 2)
                        .border(todayRing(day, selected: selected), width: calendar.isDate(day, inSameDayAs: options.today) ? 1 : 0)
                    }
                    .frame(width: cellSize, height: cellSize)
                    .opacity(calendar.isDate(day, equalTo: currentMonth, toGranularity: .month) ? 1 : 0.4))
                }
            }
        }.buttonStyle(CalendarCellStyle(width: nil, height: cellSize, isCurrentMonth: true, isToday: false))
            .flex(0, shrink: 0)
            .modifier(CalendarDayModifier(day: start, isTabStop: tabCell == start)).focusRequest(focusToken(start, isFocusable: available))
            .accessibility { $0.role = .button; $0.label = label; $0.state.isSelected = selected }
            .id(start)
    }

    private func todayRing(_ day: Date, selected: Bool) -> SemanticColorRef {
        guard options.calendar.isDate(day, inSameDayAs: options.today) else { return .clear }
        return selected ? .onAccent : .accent
    }

    // MARK: Months and years

    private func periodPanel(cellSize: Float) -> some View {
        let calendar = options.calendar
        let isMonths = session.panel == .months
        let page = isMonths ? CalendarGrid.interval(of: .year, containing: month, calendar: calendar)
            : CalendarGrid.yearPage(containing: month, calendar: calendar)
        let dates = (0..<12).compactMap { calendar.date(byAdding: isMonths ? .month : .year, value: $0, to: page.start) }
        let width = Self.panelWidth(cellSize: cellSize, granularity: options.granularity)
        let cellWidth = (width - 8) / 3, cellHeight = max(cellSize + 8, 40)
        let short = formatter(isMonths ? "MMM" : "yyyy"), full = formatter(isMonths ? "MMMM yyyy" : "yyyy")
        let cells = self.cells
        let available = dates.filter { cells.isAvailable($0, calendar: calendar, availability: options.availability) && options.presentation.isEnabled }
        let focused = cells.start(session.focusedDay, calendar: calendar)
        let tabCell = available.contains(focused) ? focused : available.first
        let title = isMonths ? formatter("yyyy").string(from: page.start)
            : "\(calendar.component(.year, from: page.start)) – \(calendar.component(.year, from: page.end) - 1)"
        return Box(direction: .column, alignItems: .stretch, spacing: 6) {
            header(title: title, label: "\(title), show years",
                   previous: isMonths ? "Previous year" : "Previous years", next: isMonths ? "Next year" : "Next years",
                   canPrevious: true, canNext: true, step: isMonths ? 12 : 144)
            for row in 0..<4 {
                AnyView(Row(alignment: .center, spacing: 4) {
                    for date in dates.dropFirst(row * 3).prefix(3) {
                        AnyView(periodCell(date, text: short.string(from: date), label: full.string(from: date),
                                           isAvailable: available.contains(date), isTabStop: tabCell == date,
                                           width: cellWidth, height: cellHeight))
                    }
                })
            }
        }.padding(10).frame(minWidth: width + 20)
            .background(.surface).cornerRadius(.controlRadius).border(.border, width: 1)
    }

    private func periodCell(_ date: Date, text: String, label: String, isAvailable: Bool, isTabStop: Bool,
                            width: Float, height: Float) -> some View {
        let component: Foundation.Calendar.Component = session.panel == .months ? .month : .year
        let selected = isSelected(date)
        let isCurrent = options.calendar.isDate(date, equalTo: options.today, toGranularity: component)
        return Button(text, isEnabled: isAvailable, isSelected: selected) { choose(date) }
            .buttonStyle(CalendarCellStyle(width: width, height: height, isCurrentMonth: true, isToday: isCurrent))
            .frame(width: width, height: height).flex(0, shrink: 0)
            .modifier(CalendarDayModifier(day: date, isTabStop: isTabStop)).focusRequest(focusToken(date, isFocusable: isAvailable))
            .accessibility { $0.role = .button; $0.label = label; $0.state.isSelected = selected }
            .id(date)
    }

    // MARK: Behaviour

    private func focusToken(_ date: Date, isFocusable: Bool) -> AnyHashable? {
        session.focusRequest > 0 && session.focusedDay == date && isFocusable ? AnyHashable(session.focusRequest) : nil
    }

    private func formatter(_ template: String) -> DateFormatter {
        let formatter = DateFormatter(); formatter.calendar = options.calendar; formatter.timeZone = options.calendar.timeZone
        formatter.locale = options.locale; formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }

    /// Selected when the cell lies in the selected period: a month cell is
    /// selected for month granularity, and highlighted no finer.
    private func isSelected(_ date: Date) -> Bool {
        guard let selected = selection.wrappedValue else { return false }
        let component = session.panel == .days ? options.granularity.component
            : session.panel == .months ? Foundation.Calendar.Component.month : .year
        guard session.panel == options.granularity.basePanel else { return false }
        return options.calendar.isDate(date, equalTo: selected, toGranularity: component)
    }

    private func isEnabled(_ day: Date) -> Bool { options.presentation.isEnabled && options.availability.contains(day, calendar: options.calendar) }

    /// A pick on the base panel selects; a pick above it drills down into it.
    private func choose(_ date: Date) {
        let calendar = options.calendar
        if session.panel == options.granularity.basePanel {
            selection.wrappedValue = CalendarGrid.start(of: options.granularity, containing: date, calendar: calendar)
            session.focusedDay = cells.start(date, calendar: calendar)
            return
        }
        guard let child = session.panel.child else { return }
        setMonth(CalendarGrid.monthStart(date, calendar: calendar))
        show(child, focusing: date)
    }

    private func drillUp() {
        guard let parent = session.panel.parent else { return }
        show(parent, focusing: selection.wrappedValue ?? month)
    }

    private func show(_ panel: CalendarPanel, focusing date: Date) {
        session.panel = panel
        session.focusedDay = CalendarCells(panel: panel, granularity: options.granularity).start(date, calendar: options.calendar)
        session.focusRequest += 1
    }

    private func browse(_ months: Int) {
        guard let next = options.calendar.date(byAdding: .month, value: months, to: month) else { return }
        setMonth(next)
    }

    private func setMonth(_ next: Date) {
        if let binding = options.visibleMonth { binding.wrappedValue = next } else { session.month = next }
    }

    private func navigate(_ date: Date, _ code: UInt32) -> Bool {
        let cells = self.cells
        guard options.presentation.isEnabled, let navigation = CalendarNavigation(scancode: code, columns: cells.columns) else { return false }
        guard let next = navigation.destination(from: date, cells: cells, calendar: options.calendar,
                                               availability: options.availability) else { return true }
        session.focusedDay = next; session.focusRequest += 1
        reveal(next)
        return true
    }

    /// Browses so the focused cell is on screen.
    private func reveal(_ cell: Date) {
        let calendar = options.calendar
        switch session.panel {
        case .days:
            let first = CalendarGrid.monthStart(month, calendar: calendar)
            guard let end = calendar.date(byAdding: .month, value: options.presentation.numberOfMonths, to: first) else { return }
            let extent = CalendarGrid.interval(of: cells.period, containing: cell, calendar: calendar)
            // A week starting before the 1st is visible in this month's grid.
            let anchor = extent.start < first ? extent.end.addingTimeInterval(-1) : extent.start
            guard anchor < first || anchor >= end else { return }
            let targetMonth = CalendarGrid.monthStart(anchor, calendar: calendar)
            setMonth(anchor < first ? targetMonth
                : calendar.date(byAdding: .month, value: 1 - options.presentation.numberOfMonths, to: targetMonth) ?? targetMonth)
        case .months:
            if !calendar.isDate(cell, equalTo: month, toGranularity: .year) { setMonth(cell) }
        case .years:
            if !CalendarGrid.yearPage(containing: month, calendar: calendar).contains(cell) { setMonth(cell) }
        }
    }
}

/// Roving focus for one cell: its date for keyboard navigation and whether
/// it is the grid's tab stop.
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
/// A day, week, month or year cell. A nil width hugs the label (week rows).
struct CalendarCellStyle: ButtonStyle {
    let width: Float?
    let height: Float
    let isCurrentMonth: Bool
    let isToday: Bool
    func makeBody(configuration c: ButtonStyleConfiguration) -> some View {
        Box(direction: .row, alignItems: .center, justifyContent: .center) { AnyView(c.label).font(.label) }
            .frame(width: width, height: height).background(c.isSelected ? c.theme.colors.accent : c.isHovered ? c.theme.colors.stateLayerHover : .clear)
            .foregroundColor(c.isSelected ? c.theme.colors.onAccent : c.isEnabled ? c.theme.colors.onSurface : c.theme.colors.onSurfaceMuted)
            .opacity(isCurrentMonth ? 1 : 0.35).cornerRadius(height / 2)
            .border(c.isFocused ? c.theme.colors.focusRing : isToday ? c.theme.colors.accent : .clear, width: c.isFocused ? 2 : isToday ? 1 : 0)
    }
}
