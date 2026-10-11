import GuavaUICompose
import GuavaUIRuntime

struct ToolbarStory: View {
    let options: GalleryOptions
    @State private var isPlaying = false
    @State private var isBold = true
    @State private var search: TextBuffer = ""
    @State private var zoomPercent = 100
    @State private var appliedSearch = "None"
    var body: some View {
        StorySection("Toolbar", "Left/Right and Home/End move focus between controls; the search field keeps its caret keys. Disabled blocks the entire bar.") {
            Toolbar(configure: { $0.isEnabled = options.isEnabled; $0.label = "Playback and formatting" }) {
                AnyView(playback)
                ToolbarSeparator()
                AnyView(formatting)
                Spacer()
                AnyView(TextField("Find in project", text: $search).frame(width: 160))
                AnyView(zoom)
            }
            Toolbar(configure: { $0.divider = .top; $0.isEnabled = options.isEnabled }) {
                Text("A bar below its content puts the divider on top.").font(.caption).foregroundColor(.onSurfaceMuted)
                Spacer()
                Button("Apply") { appliedSearch = search.isEmpty ? "None" : search.stringValue }
            }
            Text(isPlaying ? "Playback running" : "Playback stopped").font(.caption).foregroundColor(.onSurfaceMuted)
            Text("Zoom: \(zoomPercent)% · Applied filter: \(appliedSearch)").font(.caption).foregroundColor(.onSurfaceMuted)
        }
    }
    private var playback: some View {
        ToolbarGroup(label: "Playback") {
            Button(icon: .resource(UIIcons.Editor.play), isSelected: isPlaying, tooltip: "Play", action: { isPlaying = true })
            Button(icon: .resource(UIIcons.Editor.stop), isSelected: !isPlaying, tooltip: "Stop", action: { isPlaying = false })
        }
    }
    private var formatting: some View {
        ToolbarGroup(isBordered: true, label: "Formatting") {
            Button(icon: .resource(UIIcons.Text.bold), isSelected: isBold, tooltip: "Bold", action: { isBold.toggle() })
            Button(icon: .resource(UIIcons.Text.italic), isEnabled: false, tooltip: "Italic unavailable", action: {})
        }
    }
    private var zoom: some View {
        ToolbarGroup(label: "Zoom") {
            Button(icon: .resource(UIIcons.Action.zoomOut), isEnabled: zoomPercent > 50, tooltip: "Zoom out", action: { zoomPercent = max(50, zoomPercent - 10) })
            Button(icon: .resource(UIIcons.Action.zoomIn), isEnabled: zoomPercent < 200, tooltip: "Zoom in", action: { zoomPercent = min(200, zoomPercent + 10) })
        }
    }
}
