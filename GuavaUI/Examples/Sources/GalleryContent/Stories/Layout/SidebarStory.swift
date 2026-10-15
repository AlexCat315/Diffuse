import GuavaUI
import GuavaUIRuntime

struct SidebarStory: View {
    let options: GalleryOptions
    @State private var selection: String? = "downloads"
    @State private var showsIcons = true
    @State private var showsBadges = true
    @State private var drawerOpen = false

    private func item(_ id: String, _ title: String, icon: BundleImageResource?, badge: String? = nil, enabled: Bool = true) -> SidebarItem<String> {
        SidebarItem(id, title) {
            $0.icon = showsIcons ? icon : nil
            $0.badge = showsBadges ? badge : nil
            $0.isEnabled = enabled && options.isEnabled
        }
    }

    var body: some View {
        StorySection("Workspace navigation", "Native SidebarItem icons follow IconTheme and Scale. Up / Down and Home / End select enabled destinations and reveal them inside the scrolling pane.") {
            Box(direction: .row, alignItems: .center, wrap: .wrap, spacing: 16) {
                Button("Open as drawer", isEnabled: options.isEnabled) { drawerOpen = true }
                    .debugName("sidebar-open-drawer")
                Row(alignment: .center, spacing: 8) {
                    Checkbox(isOn: $showsIcons).debugName("sidebar-show-icons")
                    Text("Show icons").font(.caption)
                }
                Row(alignment: .center, spacing: 8) {
                    Checkbox(isOn: $showsBadges).debugName("sidebar-show-badges")
                    Text("Show badges").font(.caption)
                }
            }
            Box(direction: .row, alignItems: .stretch, wrap: .wrap, spacing: 20) {
                Sidebar(selection: $selection, sections: sections, header: {
                    Row(alignment: .center, spacing: 10) {
                        Icon(UIIcons.File.package, size: .large, color: .accent).flex(0, shrink: 0)
                        Text("Guava workspace").font(.bodyStrong).flex(1, shrink: 1).frame(minWidth: 0)
                    }.padding(16)
                    Divider()
                }, footer: {
                    Divider()
                    Row(alignment: .center, spacing: 8) {
                        Icon(UIIcons.Shape.circleDot, size: .small, color: .success)
                        Text("All changes saved").font(.caption).foregroundColor(.onSurfaceMuted)
                    }.padding(14)
                }).frame(width: 280, height: 360).flex(0, shrink: 0)
                    .cornerRadius(.panelRadius).border(.border, width: 1).clipped().debugName("sidebar-preview")
                Box(direction: .column, alignItems: .stretch, spacing: 12) {
                    Icon(destinationIcon, size: .large, color: .accent).frame(width: 48, height: 48)
                    Text(destinationTitle).font(.headline).debugName("sidebar-destination")
                    Text("Selection belongs to the application. This content updates when a destination is clicked or reached with the keyboard.")
                        .foregroundColor(.onSurfaceMuted)
                    Divider()
                    Text("Recent activity keeps the same text alignment without an icon. Long labels wrap, badges retain their lane, and the disabled destination cannot be activated.")
                        .font(.caption).foregroundColor(.onSurfaceMuted)
                }.padding(20).flex(1, shrink: 1, basis: 0).frame(minWidth: 260)
                    .background(.surface).cornerRadius(.panelRadius).border(.border, width: 1)
            }
            NavigationDrawer("Guava workspace", isPresented: $drawerOpen, selection: $selection, sections: sections)
        }
    }

    private var sections: [SidebarSection<String>] {
        [
            SidebarSection("workspace", title: "Workspace", items: [
                item("overview", "Overview", icon: UIIcons.Layout.dashboard),
                item("downloads", "Downloads", icon: UIIcons.Action.download, badge: "8"),
                item("projects", "Projects", icon: UIIcons.File.folder),
                item("recent", "Recent activity", icon: nil)
            ]),
            SidebarSection("preferences", title: "Preferences", items: [
                item("notifications", "Notifications", icon: UIIcons.Status.bell, badge: "3"),
                item("settings", "Settings", icon: UIIcons.Action.settings),
                item("permissions", "Team permissions unavailable", icon: UIIcons.Status.lock, enabled: false)
            ])
        ]
    }

    private var destinationTitle: String {
        switch selection {
        case "overview": "Overview"
        case "downloads": "Downloads"
        case "projects": "Projects"
        case "recent": "Recent activity"
        case "notifications": "Notifications"
        case "settings": "Settings"
        default: "Choose a destination"
        }
    }
    private var destinationIcon: BundleImageResource {
        switch selection {
        case "overview": UIIcons.Layout.dashboard
        case "downloads": UIIcons.Action.download
        case "projects": UIIcons.File.folder
        case "recent": UIIcons.Data.activity
        case "notifications": UIIcons.Status.bell
        default: UIIcons.Action.settings
        }
    }
}
