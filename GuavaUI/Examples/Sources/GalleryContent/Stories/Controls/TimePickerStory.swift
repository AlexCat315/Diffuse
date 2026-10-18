import Foundation
import GuavaUI
import GuavaUIRuntime

struct TimePickerStory: View {
    let options: GalleryOptions
    @State private var time: TimeOfDay? = TimeOfDay(hour: 9, minute: 30)
    @State private var twelveHour = true
    @State private var showsSeconds = false

    private var display: String {
        guard let time else { return "No time" }
        if twelveHour {
            let hour = time.hour % 12 == 0 ? 12 : time.hour % 12
            let suffix = time.hour < 12 ? "AM" : "PM"
            return showsSeconds
                ? String(format: "%02d:%02d:%02d %@", hour, time.minute, time.second, suffix)
                : String(format: "%02d:%02d %@", hour, time.minute, suffix)
        }
        return time.formatted(showSeconds: showsSeconds)
    }

    var body: some View {
        StorySection(
            "Inline time wheels",
            "The form owns the surface; the picker owns hour, minute, optional seconds and AM/PM. Every wheel is independently keyboard and accessibility adjustable."
        ) {
            Row(alignment: .center, spacing: 12) {
                Button("Now") {
                    let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: Date())
                    time = TimeOfDay(hour: parts.hour ?? 9, minute: parts.minute ?? 30, second: parts.second ?? 0)
                }.buttonStyle(.secondary)
                Button("Clear") { time = nil }.buttonStyle(.secondary)
                Checkbox(isOn: $twelveHour)
                Text("12-hour").font(.caption).foregroundColor(.onSurfaceMuted)
                Checkbox(isOn: $showsSeconds)
                Text("Seconds").font(.caption).foregroundColor(.onSurfaceMuted)
                Box {}.flex(1)
            }

            ThemeReader { theme in
                Box(direction: .column, alignItems: .stretch, spacing: 0) {
                    Row(alignment: .center, spacing: 8) {
                        Icon(UIIcons.Data.clock, size: .small, color: .onSurfaceMuted)
                        Text("Start time").font(.bodyStrong)
                        Box {}.flex(1)
                        Badge(display, tone: .info)
                    }
                    .padding(horizontal: 14)
                    .frame(height: 40)
                    .background(.surfaceRaised)
                    Box(direction: .row, alignItems: .center, justifyContent: .center) {
                        TimePicker(selection: $time) {
                            $0.hourCycle = twelveHour ? .twelve : .twentyFour
                            $0.minuteStep = 5
                            $0.showsSeconds = showsSeconds
                            $0.isEnabled = options.isEnabled
                        }
                        .frame(width: 330)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(vertical: 10)
                    .background(.surface)
                    Row(alignment: .center, spacing: 8) {
                        Text("Committed").font(.caption).foregroundColor(.onSurfaceMuted)
                        Text(display).font(.bodyStrong)
                        Box {}.flex(1)
                        Text(twelveHour ? "12-hour · 5 min" : "24-hour · 5 min")
                            .font(.caption).foregroundColor(.onSurfaceMuted)
                    }
                    .padding(horizontal: 14)
                    .frame(height: 36)
                    .background(.surfaceRaised)
                }
                .border(.border, width: 1)
                .cornerRadius(theme.radius.md)
                .clipped()
            }

            Text("The inline picker is independent of the trigger. Use it inside a Popover, Sheet or a form card; TimeField remains the validated text entry for keyboard-first forms.")
                .font(.caption).foregroundColor(.onSurfaceMuted)
        }
    }
}
