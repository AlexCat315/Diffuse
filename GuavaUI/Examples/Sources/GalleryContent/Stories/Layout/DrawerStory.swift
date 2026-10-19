import GuavaUI
import GuavaUIRuntime

struct NavigationDrawerStory: View {
    let options: GalleryOptions
    @State private var open = false
    @State private var selection: Int? = 8
    @State private var closesOnSelection = true
    @State private var swipe = true
    var body: some View {
        StorySection(
            "Modal workspace navigation",
            "Open a leading drawer, then collapse it with the sidebar toggle or tap outside. Its width follows the window, leaving at least 56 points outside. Arrow keys browse; Enter chooses. Swipe left or press Escape to dismiss; focus returns to the opener."
        ) {
            Box(direction: .row, alignItems: .center, wrap: .wrap, spacing: 16) {
                Button("Open navigation", isEnabled: options.isEnabled) { open = true }
                    .debugName("drawer-open")
                Row(alignment: .center, spacing: 8) {
                    Checkbox(isOn: $closesOnSelection, isEnabled: options.isEnabled)
                    Text("Close after choosing").font(.caption)
                }
                Row(alignment: .center, spacing: 8) {
                    Checkbox(isOn: $swipe, isEnabled: options.isEnabled)
                    Text("Swipe to dismiss").font(.caption)
                }
            }
            Text("Selected destination: \(selection.map(String.init) ?? "none")")
                .font(.caption).foregroundColor(.onSurfaceMuted).debugName("drawer-selection")
            NavigationDrawer(
                "Guava workspace", isPresented: $open, selection: $selection,
                sections: [
                    SidebarSection(
                        "workspace", title: "Workspace",
                        items: (0..<20).map { index in
                            SidebarItem(index, index == 4 ? "Unavailable destination" : "Destination \(index)") {
                                $0.icon = index % 2 == 0 ? UIIcons.File.folder : UIIcons.Layout.dashboard
                                $0.badge = index == 8 ? "8" : nil
                                $0.isEnabled = index != 4
                            }
                        })
                ],
                configure: {
                    $0.closesOnSelection = closesOnSelection
                    $0.allowsSwipeDismissal = swipe
                },
                header: {
                    Text("Browse destinations without losing the current workspace.")
                        .font(.caption).foregroundColor(.onSurfaceMuted).padding(12)
                },
                footer: {
                    Divider()
                    Text("All changes saved").font(.caption).foregroundColor(.onSurfaceMuted).padding(14)
                })
        }
    }
}
