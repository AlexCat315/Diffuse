import Foundation
import GuavaUIRuntime

public struct DateRangePickerPresentation {
    public var placeholder = "Choose dates"
    public var isClearable = true
    public var isEnabled = true
    public var width: Float = 260
    public init() {}
}

public struct DateRangePickerOptions {
    public var calendar = CalendarOptions()
    public var presentation = DateRangePickerPresentation()
    public init() {}
}

/// Range picker backed by a real calendar. First click starts a range, second
/// click completes it (the earlier day becomes the start when clicked second).
public struct DateRangePicker: View {
    public let selection: Binding<ClosedRange<Date>?>
    public var options = DateRangePickerOptions()

    @State private var isPresented = false

    public init(selection: Binding<ClosedRange<Date>?>,
                configure: (inout DateRangePickerOptions) -> Void = { _ in }) {
        self.selection = selection
        configure(&options)
        options.presentation.width = max(160, options.presentation.width)
        options.calendar.presentation.validate()
    }

    public var body: some View {
        let formatter = rangeFormatter
        let width = Float(options.calendar.presentation.numberOfMonths)
            * (options.calendar.presentation.cellSize * 7 + 36)
        return Popover(isPresented: $isPresented,
                       isEnabled: options.presentation.isEnabled,
                       width: width,
                       surface: .content, overflow: .flip, label: {
            Row(alignment: .center, spacing: 8) {
                Text(labelText(formatter)).font(.label)
                Spacer()
                if options.presentation.isClearable && selection.wrappedValue != nil {
                    Button(icon: .resource(UIIcons.Action.x), size: 12,
                           isEnabled: options.presentation.isEnabled,
                           tooltip: "Clear dates") {
                        selection.wrappedValue = nil
                    }.buttonStyle(.ghost).controlSize(.mini)
                }
                Icon(UIIcons.Navigation.chevronDown, size: .small)
            }
            .padding(horizontal: 10, vertical: 6)
            .frame(minHeight: 34)
            .background(.surface)
            .cornerRadius(.inputRadius)
            .border(.border, width: 1)
        }, content: {
            DateRangeCalendar(selection: selection) {
                $0 = options.calendar
                $0.presentation.isEnabled = options.presentation.isEnabled
            }
        })
        .frame(width: options.presentation.width)
        .accessibility {
            $0.label = options.presentation.placeholder
            $0.value = labelText(formatter)
            $0.state.isExpanded = isPresented
        }
    }

    private var rangeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.locale = options.calendar.locale
        formatter.calendar = options.calendar.calendar
        formatter.timeZone = options.calendar.calendar.timeZone
        return formatter
    }

    private func labelText(_ formatter: DateFormatter) -> String {
        guard let range = selection.wrappedValue else { return options.presentation.placeholder }
        return "\(formatter.string(from: range.lowerBound)) – \(formatter.string(from: range.upperBound))"
    }
}

private struct RangeCalendarSession {
    var month: Date
    var focusedDay: Date
    var focusRequest = 0
}

/// Calendar with range highlighting and two-click range selection.
public struct DateRangeCalendar: View {
    public let selection: Binding<ClosedRange<Date>?>
    public var options = CalendarOptions()

    @State private var session: RangeCalendarSession
    @State private var pendingStart: Date?

    public init(selection: Binding<ClosedRange<Date>?>,
                configure: (inout CalendarOptions) -> Void = { _ in }) {
        self.selection = selection
        configure(&options)
        options.presentation.validate()
        options.calendar.firstWeekday = min(7, max(1, options.calendar.firstWeekday))
        let initial = selection.wrappedValue?.lowerBound ?? options.today
        _session = State(wrappedValue: RangeCalendarSession(
            month: CalendarGrid.monthStart(initial, calendar: options.calendar),
            focusedDay: options.calendar.startOfDay(for: initial)))
    }

    public var body: some View {
        SurfaceReader { surface in
            let cellSize = max(options.presentation.cellSize,
                               surface.input.contains(.touch) ? surface.minimumControlExtent : 0)
            CalendarKeyHost(onNavigate: navigate) {
                Box(direction: .row, alignItems: .flexStart, wrap: .wrap, spacing: 16) {
                    for index in 0..<options.presentation.numberOfMonths {
                        AnyView(monthView(options.calendar.date(byAdding: .month, value: index, to: month) ?? month,
                                          index: index, cellSize: cellSize))
                    }
                }
            }.accessibility { $0.role = .group; $0.label = "Date range" }
        }
    }

    private var month: Date { options.visibleMonth?.wrappedValue ?? session.month }

    private func monthView(_ date: Date, index: Int, cellSize: Float) -> some View {
        let days = CalendarGrid.days(in: date, calendar: options.calendar)
        let formatter = DateFormatter()
        formatter.calendar = options.calendar
        formatter.timeZone = options.calendar.timeZone
        formatter.locale = options.calendar.locale
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        let symbols = formatter.veryShortStandaloneWeekdaySymbols ?? ["S", "M", "T", "W", "T", "F", "S"]
        let monthDays = days.filter {
            options.calendar.isDate($0, equalTo: date, toGranularity: .month) && isEnabled($0)
        }
        let tabDay = monthDays.first { options.calendar.isDate($0, inSameDayAs: session.focusedDay) }
            ?? monthDays.first
        return Box(direction: .column, alignItems: .stretch, spacing: 6) {
            Row(alignment: .center, spacing: 4) {
                Button(icon: .resource(UIIcons.Navigation.chevronLeft), size: 12,
                       isEnabled: options.presentation.isEnabled && index == 0) { browse(-1) }
                    .buttonStyle(.ghost).accessibilityLabel("Previous month")
                Text(formatter.string(from: date)).font(.bodyStrong).flex(1).padding(horizontal: 4)
                Button(icon: .resource(UIIcons.Navigation.chevronRight), size: 12,
                       isEnabled: options.presentation.isEnabled && index == options.presentation.numberOfMonths - 1) { browse(1) }
                    .buttonStyle(.ghost).accessibilityLabel("Next month")
            }
            Row(alignment: .center, spacing: 2) {
                for weekday in 0..<7 {
                    AnyView(Text(symbols[(weekday + options.calendar.firstWeekday - 1) % 7])
                        .font(.caption).foregroundColor(.onSurfaceMuted)
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
        }.padding(10).background(.surface).cornerRadius(.controlRadius).border(.border, width: 1)
    }

    private func dayView(_ day: Date, currentMonth: Date, tabDay: Date?, cellSize: Float) -> some View {
        let calendar = options.calendar
        let inMonth = calendar.isDate(day, equalTo: currentMonth, toGranularity: .month)
        let range = selection.wrappedValue
        let inRange = range.map { $0.contains(day) } ?? false
        let isStart = range.map { calendar.isDate(day, inSameDayAs: $0.lowerBound) } ?? false
        let isEnd = range.map { calendar.isDate(day, inSameDayAs: $0.upperBound) } ?? false
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = options.calendar.locale
        return ZStack {
            if inRange {
                Box {}.frame(width: cellSize, height: cellSize)
                    .background(.stateLayerSelected).cornerRadius(4)
            }
            Button(String(calendar.component(.day, from: day)),
                   isEnabled: inMonth && isEnabled(day),
                   isSelected: isStart || isEnd) {
                choose(day)
            }
            .buttonStyle(CalendarDayStyle(cellSize: cellSize,
                                          isCurrentMonth: inMonth,
                                          isToday: calendar.isDate(day, inSameDayAs: options.today)))
            .frame(width: cellSize, height: cellSize)
            .modifier(CalendarDayModifier(day: day, isTabStop: tabDay == day))
            .accessibility {
                $0.role = .button
                $0.label = formatter.string(from: day)
                $0.state.isSelected = isStart || isEnd
            }
            .focusRequest(session.focusRequest > 0 && session.focusedDay == day && inMonth && isEnabled(day)
                ? AnyHashable(session.focusRequest) : nil)
        }
        .frame(width: cellSize, height: cellSize).flex(0, shrink: 0)
        .id(day)
    }

    private func choose(_ day: Date) {
        let calendar = options.calendar
        let value = calendar.startOfDay(for: day)
        if let pendingStart {
            let lower = min(pendingStart, value)
            let upper = max(pendingStart, value)
            selection.wrappedValue = calendar.startOfDay(for: lower)...calendar.startOfDay(for: upper)
            self.pendingStart = nil
        } else {
            self.pendingStart = value
            selection.wrappedValue = value...value
        }
        session.focusedDay = value
    }

    private func isEnabled(_ day: Date) -> Bool {
        options.presentation.isEnabled
            && options.availability.contains(day, calendar: options.calendar)
    }

    private func browse(_ value: Int) {
        guard let next = options.calendar.date(byAdding: .month, value: value, to: month) else { return }
        if let binding = options.visibleMonth { binding.wrappedValue = next } else { session.month = next }
    }

    private func navigate(_ date: Date, _ code: UInt32) -> Bool {
        guard options.presentation.isEnabled,
              let navigation = CalendarNavigation(scancode: code),
              let next = navigation.destination(from: date, calendar: options.calendar,
                                               availability: options.availability) else { return false }
        session.focusedDay = next
        session.focusRequest += 1
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
        if let binding = options.visibleMonth { binding.wrappedValue = next } else { session.month = next }
    }
}
