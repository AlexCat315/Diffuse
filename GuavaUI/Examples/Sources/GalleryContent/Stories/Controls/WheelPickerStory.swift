import Foundation
import GuavaUI
import GuavaUIRuntime

struct WheelPickerStory: View {
    let options: GalleryOptions
    @State private var hour = 9
    @State private var minute = 30
    @State private var period = 0
    @State private var volume = 6
    @State private var enabled = true

    private let hours = (0..<12).map { WheelPickerOption($0, String(format: "%02d", $0 == 0 ? 12 : $0)) }
    private let minutes = stride(from: 0, to: 60, by: 5).map {
        WheelPickerOption($0, String(format: "%02d", $0))
    }
    private let periods = [WheelPickerOption(0, "AM"), WheelPickerOption(1, "PM")]
    private let volumes = (0...10).map { WheelPickerOption($0, "\($0)", isEnabled: $0 != 10) }

    private var timeLabel: String {
        String(format: "%02d:%02d %@", hour == 0 ? 12 : hour, minute, period == 0 ? "AM" : "PM")
    }

    var body: some View {
        StorySection(
            "Wheel selection",
            "Scroll, drag, click a row or use arrow keys / Home / End. The center band marks the committed value; disabled rows are skipped."
        ) {
            Row(alignment: .center, spacing: 12) {
                Button("Now") {
                    let parts = Calendar.current.dateComponents([.hour, .minute], from: Date())
                    let h = (parts.hour ?? 9) % 12
                    hour = h == 0 ? 12 : h
                    minute = ((parts.minute ?? 30) / 5) * 5
                    period = (parts.hour ?? 9) >= 12 ? 1 : 0
                }.buttonStyle(.secondary)
                Button("Reset") { hour = 9; minute = 30; period = 0; volume = 6 }
                    .buttonStyle(.secondary)
                Checkbox(isOn: $enabled)
                Text("Enabled").font(.caption).foregroundColor(.onSurfaceMuted)
                Box {}.flex(1)
            }

            ThemeReader { theme in
                Box(direction: .column, alignItems: .stretch, spacing: 0) {
                    Row(alignment: .center, spacing: 8) {
                        Icon(UIIcons.Data.clock, size: .small, color: .onSurfaceMuted)
                        Text("Start time").font(.bodyStrong)
                        Box {}.flex(1)
                        Badge(timeLabel, tone: .info)
                    }
                    .padding(horizontal: 14)
                    .frame(height: 40)
                    .background(.surfaceRaised)
                    Box(direction: .row, alignItems: .center, justifyContent: .center, spacing: 10) {
                        wheel(hours, selection: $hour, label: "Hour")
                        colon
                        wheel(minutes, selection: $minute, label: "Minute")
                        wheel(periods, selection: $period, label: "AM or PM")
                    }
                    .padding(vertical: 6)
                    .frame(maxWidth: .infinity)
                    .background(.surface)
                    Row(alignment: .center, spacing: 8) {
                        Text("Output").font(.caption).foregroundColor(.onSurfaceMuted)
                        Text(timeLabel).font(.bodyStrong)
                        Box {}.flex(1)
                        Text("5 min").font(.caption).foregroundColor(.onSurfaceMuted)
                    }
                    .padding(horizontal: 14)
                    .frame(height: 36)
                    .background(.surfaceRaised)
                }
                .border(.border, width: 1)
                .cornerRadius(theme.radius.md)
                .clipped()
            }

            Column(alignment: .leading, spacing: 8) {
                Text("Volume").font(.label)
                Text("A second wheel demonstrates step and disabled states.").font(.caption).foregroundColor(.onSurfaceMuted)
                Row(alignment: .center, spacing: 12) {
                    WheelPicker(selection: $volume, options: volumes, isEnabled: enabled, visibleRows: 3, label: "Volume")
                        .frame(width: 100)
                    Text("\(volume)").font(.bodyStrong).frame(width: 28)
                }
            }
            .padding(12)
            .background(.surface)
            .border(.border, width: 1)
            .cornerRadius(8)
        }
    }

    private func wheel(_ options: [WheelPickerOption<Int>], selection: Binding<Int>, label: String) -> some View {
        WheelPicker(selection: selection, options: options, isEnabled: enabled,
                    visibleRows: 5, label: label) { _ in }
            .frame(width: label == "AM or PM" ? 72 : 82)
    }

    private var colon: some View {
        Text(":").font(.title).foregroundColor(.onSurfaceMuted).padding(EdgeInsets(top: 2))
    }
}
