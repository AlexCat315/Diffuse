import GuavaUI
import GuavaUIRuntime

struct NavigationRailStory: View {
    let options: GalleryOptions
    @State private var selection: Int? = 0
    @State private var labels = true
    @State private var presentation = SidebarPresentation.expanded
    @State private var activations = 0

    private var items: [SidebarItem<Int>] {
        [
            SidebarItem(0, "Overview") {
                $0.icon = UIIcons.Layout.dashboard
                $0.isEnabled = options.isEnabled
            },
            SidebarItem(1, "Projects") {
                $0.icon = UIIcons.File.folder
                $0.badge = "12"
                $0.isEnabled = options.isEnabled
            },
            SidebarItem(2, "Notifications") {
                $0.icon = UIIcons.Status.bell
                $0.badge = "999"
                $0.isEnabled = options.isEnabled
            },
            SidebarItem(3, "Unavailable") {
                $0.icon = UIIcons.Status.lock
                $0.isEnabled = false
            },
            SidebarItem(4, "Workspace permissions") { $0.isEnabled = options.isEnabled },
        ]
    }
    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 24) {
            StorySection(
                "Rail destinations",
                "The 72-point rail keeps labels; hiding them uses 56 points and retains complete names in tooltips and accessibility. Use Up / Down and Home / End. Disabled destinations are skipped; badges keep their full value."
            ) {
                Row(alignment: .center, spacing: 8) {
                    Checkbox(isOn: $labels, isEnabled: options.isEnabled).debugName("rail-show-labels")
                    Text("Show labels").font(.caption)
                }
                Box(direction: .row, alignItems: .stretch, spacing: 20) {
                    NavigationRail(
                        selection: $selection, items: items, showsLabels: labels,
                        onActivate: { _ in activations += 1 },
                        header: {
                            Button(
                                icon: .resource(UIIcons.Layout.dashboard), isEnabled: options.isEnabled,
                                tooltip: "Workspace home"
                            ) { selection = 0 }.buttonStyle(.ghost).frame(minWidth: 44, minHeight: 44)
                        },
                        footer: {
                            Button(
                                icon: .resource(UIIcons.Action.settings), isEnabled: options.isEnabled,
                                tooltip: "Workspace settings"
                            ) { selection = 4 }.buttonStyle(.ghost).frame(minWidth: 44, minHeight: 44)
                        }
                    ).frame(height: 320).debugName("gallery-rail")
                    Text("Selected: \(selection.map(String.init) ?? "none") · Activations: \(activations)")
                        .font(.body).flex(1, shrink: 1).frame(minWidth: 0).debugName("rail-summary")
                }
            }
            StorySection(
                "Retained presentations",
                "A Sidebar can switch between full, labeled rail and icon-only rail while preserving destination nodes, focus and selection. The shell chooses which form fits its available space."
            ) {
                Select(
                    selection: Binding(get: { presentation }, set: { presentation = $0 }),
                    options: [
                        SelectOption(value: SidebarPresentation.expanded, label: "Full sidebar"),
                        SelectOption(value: .rail(showsLabels: true), label: "Rail with labels"),
                        SelectOption(value: .rail(showsLabels: false), label: "Icon rail"),
                    ]
                ).frame(maxWidth: 280).debugName("rail-presentation")
                Sidebar(
                    selection: $selection, sections: [SidebarSection("workspace", title: "Workspace", items: items)],
                    presentation: presentation
                ).frame(height: 280, maxWidth: 240).debugName("gallery-retained-rail")
            }
        }
    }
}
