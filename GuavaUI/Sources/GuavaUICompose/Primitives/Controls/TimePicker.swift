import GuavaUIRuntime

public enum TimeHourCycle: Sendable, Equatable {
    case twentyFour
    case twelve
}

public struct TimePickerOptions {
    public var hourCycle: TimeHourCycle = .twentyFour
    public var minuteStep = 5
    public var showsSeconds = false
    public var isEnabled = true
    public var minimum = TimeOfDay()
    public var maximum = TimeOfDay(hour: 23, minute: 59, second: 59)
    public var label = "Time"
    public init() {}

    mutating func validate() {
        minuteStep = min(60, max(1, minuteStep))
        maximum = max(minimum, maximum)
    }
}

/// Inline wheel time editor. The host supplies the field chrome or a popover;
/// this view owns only the wheel columns and the committed `TimeOfDay`.
public struct TimePicker: View {
    public let selection: Binding<TimeOfDay?>
    public var options = TimePickerOptions()
    public var onChange: ((TimeOfDay) -> Void)?

    public init(selection: Binding<TimeOfDay?>,
                configure: (inout TimePickerOptions) -> Void = { _ in },
                onChange: ((TimeOfDay) -> Void)? = nil) {
        self.selection = selection
        configure(&options)
        options.validate()
        self.onChange = onChange
    }

    public var body: some View {
        Row(alignment: .center, spacing: 8) {
            wheel("Hour", options: hours, value: hour, width: 68)
            separator
            wheel("Minute", options: minutes, value: minute, width: 68)
            if options.showsSeconds {
                separator
                wheel("Second", options: seconds, value: second, width: 68)
            }
            if options.hourCycle == .twelve {
                wheel("AM or PM", options: periods, value: period, width: 68)
            }
        }
        .accessibility { $0.role = .group; $0.label = options.label }
    }

    private var current: TimeOfDay {
        let candidate = selection.wrappedValue ?? options.minimum
        return TimeOfDay(hour: min(options.maximum.hour, max(options.minimum.hour, candidate.hour)),
                         minute: candidate.minute, second: candidate.second)
    }

    private var hour: Binding<Int> {
        Binding(get: {
            options.hourCycle == .twelve
                ? (current.hour % 12 == 0 ? 12 : current.hour % 12)
                : current.hour
        }, set: { value in
            let base = options.hourCycle == .twelve && current.hour >= 12 ? 12 : 0
            let hour = options.hourCycle == .twelve ? (value % 12) + base : value
            commit(TimeOfDay(hour: hour, minute: current.minute, second: current.second))
        })
    }

    private var minute: Binding<Int> {
        Binding(get: { current.minute / options.minuteStep * options.minuteStep },
                set: { commit(TimeOfDay(hour: current.hour, minute: $0, second: current.second)) })
    }

    private var second: Binding<Int> {
        Binding(get: { current.second },
                set: { commit(TimeOfDay(hour: current.hour, minute: current.minute, second: $0)) })
    }

    private var period: Binding<Int> {
        Binding(get: { current.hour >= 12 ? 1 : 0 },
                set: { value in
                    let hour = (current.hour % 12) + (value == 1 ? 12 : 0)
                    commit(TimeOfDay(hour: hour, minute: current.minute, second: current.second))
                })
    }

    private var hours: [WheelPickerOption<Int>] {
        if options.hourCycle == .twelve {
            return (1...12).map { WheelPickerOption($0, String(format: "%02d", $0)) }
        }
        return (0...23).map { WheelPickerOption($0, String(format: "%02d", $0)) }
    }

    private var minutes: [WheelPickerOption<Int>] {
        Array(stride(from: 0, to: 60, by: options.minuteStep)).map {
            WheelPickerOption($0, String(format: "%02d", $0))
        }
    }

    private var seconds: [WheelPickerOption<Int>] {
        (0...59).map { WheelPickerOption($0, String(format: "%02d", $0)) }
    }

    private var periods: [WheelPickerOption<Int>] {
        [WheelPickerOption(0, "AM"), WheelPickerOption(1, "PM")]
    }

    private func wheel(_ label: String, options entries: [WheelPickerOption<Int>],
                        value: Binding<Int>, width: Float) -> some View {
        WheelPicker(selection: value, options: entries, isEnabled: options.isEnabled,
                    visibleRows: 5, label: label)
            .frame(width: width)
    }

    private var separator: some View {
        Text(":").font(.title).foregroundColor(.onSurfaceMuted)
    }

    private func commit(_ time: TimeOfDay) {
        let seconds = min(options.maximum.seconds, max(options.minimum.seconds, time.seconds))
        let next = TimeOfDay(hour: seconds / 3600, minute: seconds / 60 % 60, second: seconds % 60)
        selection.wrappedValue = next
        onChange?(next)
    }
}
