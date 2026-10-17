import Foundation
import GuavaUIRuntime

public struct DatePickerPresentation {
    public var placeholder = "Choose a date"
    public var isClearable = true
    public var isEnabled = true
    public var width: Float = 240
    public init() {}
}
public struct DatePickerOptions {
    public var calendar = CalendarOptions()
    public var presentation = DatePickerPresentation()
    public init() {}
}
public struct DatePicker: View {
    public let selection: Binding<Date?>
    public var options = DatePickerOptions()
    @State private var isPresented = false
    public init(selection: Binding<Date?>, configure: (inout DatePickerOptions) -> Void = { _ in }) {
        self.selection = selection; configure(&options); options.presentation.width = max(140, options.presentation.width)
        options.calendar.presentation.validate()
    }
    public var body: some View {
        let formatter = DateFormatter(); formatter.dateStyle = .medium; formatter.locale = options.calendar.locale
        formatter.calendar = options.calendar.calendar; formatter.timeZone = options.calendar.calendar.timeZone
        let dateLabel = selection.wrappedValue.map(formatter.string) ?? options.presentation.placeholder
        return Popover(isPresented: $isPresented, isEnabled: options.presentation.isEnabled,
                       width: Float(options.calendar.presentation.numberOfMonths) * (options.calendar.presentation.cellSize * 7 + 36), label: {
            Row(alignment: .center, spacing: 8) {
                Text(dateLabel).truncatingTail().font(.label).tooltip(dateLabel)
                    .flex(1, shrink: 1).frame(minWidth: 0)
                if options.presentation.isClearable && selection.wrappedValue != nil {
                    Button(icon: .resource(UIIcons.Action.x), size: 12, isEnabled: options.presentation.isEnabled,
                           tooltip: "Clear date") { selection.wrappedValue = nil }.buttonStyle(.ghost).controlSize(.mini)
                }
                Icon(UIIcons.Navigation.chevronDown, size: .small)
            }.padding(horizontal: 10, vertical: 6).frame(minHeight: 34).background(.surface).cornerRadius(.inputRadius).border(.border, width: 1)
        }, content: {
            CalendarView(selection: Binding(get: { selection.wrappedValue }, set: { selection.wrappedValue = $0; isPresented = false })) {
                $0 = options.calendar; $0.presentation.isEnabled = options.presentation.isEnabled
            }
        }).frame(width: options.presentation.width).accessibility {
            $0.label = options.presentation.placeholder
            $0.value = selection.wrappedValue.map(formatter.string) ?? ""
            $0.state.isExpanded = isPresented
        }
    }
}
