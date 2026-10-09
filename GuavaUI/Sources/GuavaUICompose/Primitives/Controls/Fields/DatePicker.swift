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
        return Popover(isPresented: $isPresented, isEnabled: options.presentation.isEnabled,
                       width: Float(options.calendar.presentation.numberOfMonths) * (options.calendar.presentation.cellSize * 7 + 36), label: {
            Row(alignment: .center, spacing: 8) {
                Text(selection.wrappedValue.map(formatter.string) ?? options.presentation.placeholder).font(.label)
                Spacer()
                if options.presentation.isClearable && selection.wrappedValue != nil {
                    Button(icon: .resource(UICommonIcons.close), size: 12, isEnabled: options.presentation.isEnabled,
                           tooltip: "Clear date") { selection.wrappedValue = nil }.buttonStyle(.ghost).controlSize(.mini)
                }
                Icon(UICommonIcons.chevronDown, size: 10)
            }.padding(horizontal: 10).frame(height: 34).background(.surface).cornerRadius(6).border(.border, width: 1)
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
