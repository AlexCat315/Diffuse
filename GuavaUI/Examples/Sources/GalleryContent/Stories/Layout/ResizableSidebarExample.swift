import GuavaUI

struct ResizableSidebarExample: View {
    let options: GalleryOptions
    @State private var width: Float = 240
    @State private var selected: Int? = 0
    @State private var draft: TextBuffer = "A retained document draft"
    var body: some View {
        StorySection("Resizable navigation", "Drag the separator or focus it and use Left/Right, Shift for larger steps, Home/End for the limits. Compact layouts retain the requested width. This embedded example uses a 600pt expanded threshold.") {
            AdaptiveSidebar("Document navigation", selection: $selected,
                width: options.isEnabled ? $width : nil,
                sections: [SidebarSection("documents", items: [
                    SidebarItem(0, "Overview") { $0.isEnabled = options.isEnabled },
                    SidebarItem(1, "Documents") { $0.isEnabled = options.isEnabled }
                ])],
                configure: {
                    $0.layout.sidebarWidth = width
                    $0.layout.compactMaximumWidth = 400; $0.layout.expandedMinimumWidth = 600
                    $0.resizing.minimumContentWidth = 240
                    $0.resizing.label = "Resize example navigation"
                }) {
                    Box(direction: .column, alignItems: .stretch, spacing: 12) {
                        TextField("Document draft", text: $draft) { $0.behavior.disabled = !options.isEnabled }
                        Text("Selected: \(selected ?? 0)").font(.caption)
                    }.padding(12)
                }.frame(height: 220).border(.border, width: 1).clipped()
            Button("Reset navigation width", isEnabled: options.isEnabled) { width = 240 }.buttonStyle(.ghost)
            Text("Requested width: \(Int(width.rounded())) pt").font(.caption).foregroundColor(.onSurfaceMuted)
        }
    }
}
