import GuavaUI
import GuavaUIRuntime

struct NestedSidebarExample: View {
  let options: GalleryOptions
  @State private var selection: String? = "nested-overview"
  @State private var expanded: Set<String> = ["nested-projects"]
  @State private var open = false
  @State private var draft: TextBuffer = "A retained nested document"

  var body: some View {
    StorySection("Nested navigation", "Groups expand without changing the page. Up/Down visits visible items; Right opens a group or enters its first child, Left closes it or returns to its parent. Collapsing preserves the selected document.") {
      Box(direction: .row, alignItems: .center, wrap: .wrap, spacing: 8) {
        Button("Expand navigation groups", isEnabled: options.isEnabled) { expanded = ["nested-projects", "nested-team"] }.buttonStyle(.secondary)
        Button("Collapse navigation groups", isEnabled: options.isEnabled) { expanded = [] }.buttonStyle(.secondary)
        Button("Open nested drawer", isEnabled: options.isEnabled) { open = true }.buttonStyle(.secondary)
      }
      AdaptiveSidebar("Nested workspace", isPresented: $open, selection: $selection, expanded: $expanded,
                      sections: sections, configure: {
        $0.layout.compactMaximumWidth = 400; $0.layout.expandedMinimumWidth = 600
        $0.layout.showsRailLabels = false; $0.openLabel = "Open nested navigation"
        $0.drawer.closeLabel = "Close nested navigation"
      }) {
        Box(direction: .column, alignItems: .stretch, spacing: 12) {
          TextField("Nested document draft", text: $draft) { $0.behavior.disabled = !options.isEnabled }
          Text("Selected destination: \(selection ?? "none")").font(.caption)
        }.padding(12)
      }.frame(height: 280).border(.border, width: 1).clipped()
    }
  }
  private var sections: [SidebarSection<String>] {
    [SidebarSection("nested-workspace", items: [
      item("nested-overview", "Workspace overview", icon: UIIcons.Layout.dashboard),
      item("nested-projects", "Project spaces", icon: UIIcons.File.folder, children: [
        item("nested-welcome", "Getting started"),
        item("nested-team", "Design team", children: [
          item("nested-audit", "Audit log"), item("nested-billing", "Billing", enabled: false)
        ])
      ])
    ])]
  }
  private func item(_ id: String, _ title: String, icon: BundleImageResource? = nil,
                    enabled: Bool = true, children: [SidebarItem<String>] = []) -> SidebarItem<String> {
    SidebarItem(id, title) { $0.icon = icon; $0.isEnabled = enabled && options.isEnabled; $0.children = children }
  }
}
