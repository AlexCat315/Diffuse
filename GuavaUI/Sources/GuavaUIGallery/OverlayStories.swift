import GuavaUICompose
import GuavaUIRuntime

struct MenuStory: View {
    let options: GalleryOptions
    @State private var status = "Choose a command"
    @State private var checked = true
    @State private var open = false
    @State private var manyOpen = false
    var entries: [MenuEntry] {
        [.label(id: "workspace", title: "Workspace"),
         .item(MenuItem(id: "copy", title: "Copy", shortcut: KeyboardShortcut.primary("C").displayString, isEnabled: options.isEnabled, action: { status = "Copied" })),
         .item(MenuItem(id: "pin", title: "Pin item", isEnabled: options.isEnabled, isSelected: checked, action: { checked.toggle() })),
         .separator(id: "actions"),
         .submenu(MenuSubmenu(id: "settings", title: "Settings", entries: [
            .item(MenuItem(id: "general", title: "General", action: { status = "General settings" })),
            .submenu(MenuSubmenu(id: "appearance", title: "Appearance", entries: [
                .item(MenuItem(id: "system", title: "System theme", isSelected: true, action: { status = "System theme" })),
                .submenu(MenuSubmenu(id: "colors", title: "Accent color", entries: [
                    .item(MenuItem(id: "blue", title: "Blue", action: { status = "Blue accent" })),
                    .item(MenuItem(id: "green", title: "Green", action: { status = "Green accent" }))
                ]))
            ])),
            .item(MenuItem(id: "restricted", title: "Restricted", isEnabled: false, action: {}))
         ], configure: { $0.isEnabled = options.isEnabled; $0.width = 240 })),
         .item(MenuItem(id: "unavailable", title: "Unavailable", isEnabled: false, action: {})),
         .item(MenuItem(id: "delete", title: "Delete", isEnabled: options.isEnabled, role: .destructive, action: { status = "Deleted" }))]
    }
    var manyEntries: [MenuEntry] {
        (0..<100).map { index in
            if index.isMultiple(of: 10) {
                return .submenu(MenuSubmenu(id: index, title: "Group \(index)", entries: [
                    .item(MenuItem(id: "inspect", title: "Inspect group", action: { status = "Inspect group \(index)" })),
                    .item(MenuItem(id: "export", title: "Export group", action: { status = "Export group \(index)" }))
                ]))
            }
            return .item(MenuItem(id: index, title: "Command \(index)", action: { status = "Command \(index)" }))
        }
    }
    var body: some View {
        StorySection("Nested commands", "Use Up/Down, Home/End or type a label. Right opens a branch; Left and Escape return one level. A leaf closes the entire popup.") {
            Popover(isPresented: $open, isEnabled: options.isEnabled, width: 260) {
                Row(alignment: .center, spacing: 8) { Text("Workspace commands").font(.body); Icon(UICommonIcons.chevronDown, size: 12) }
            } content: { Menu(entries, width: 260, onItemActivated: { open = false }) }
            Text(status).font(.caption).foregroundColor(.onSurfaceMuted)
        }
        StorySection("Inline menu", "Shared selection columns, labels, separators, disabled actions and destructive color. Submenus escape the card's clipping.") {
            Menu(entries, width: 260)
        }
        StorySection("Scrollable menu", "100 commands with nested branches. Keyboard navigation reveals the active row; a child closes when its anchor scrolls away.") {
            Popover(isPresented: $manyOpen, isEnabled: options.isEnabled, width: 240) {
                Row(alignment: .center, spacing: 8) { Text("100 commands").font(.body); Icon(UICommonIcons.chevronDown, size: 12) }
            } content: { Menu(manyEntries, width: 240, maxVisibleRows: 6, onItemActivated: { manyOpen = false }) }
        }
    }
}

struct ContextMenuStory: View {
    let options: GalleryOptions
    @State private var status = "Right-click the target"
    var body: some View {
        StorySection("Context actions", "The menu is positioned at the pointer and dismissed by Escape or clicking outside.") {
            Text("Right-click this surface").font(.body).padding(40).background(.surfaceVariant).cornerRadius(8)
                .contextMenu([
                    .item(MenuItem(title: "Open", isEnabled: options.isEnabled, action: { status = "Opened" })),
                    .item(MenuItem(title: "Duplicate", isEnabled: options.isEnabled, action: { status = "Duplicated" })),
                    .separator("nested"),
                    .submenu(MenuSubmenu(id: "organize", title: "Organize", entries: [
                        .item(MenuItem(id: "move", title: "Move to folder", action: { status = "Moved to folder" })),
                        .submenu(MenuSubmenu(id: "export", title: "Export", entries: [
                            .item(MenuItem(id: "json", title: "JSON", action: { status = "Exported JSON" })),
                            .item(MenuItem(id: "swift", title: "Swift", action: { status = "Exported Swift" }))
                        ]))
                    ], configure: { $0.isEnabled = options.isEnabled }))
                ])
            Text(status).font(.caption).foregroundColor(.onSurfaceMuted)
        }
    }
}

struct PopoverStory: View {
    let options: GalleryOptions
    @State private var open = false
    @State private var name: TextBuffer = "New project"
    var body: some View {
        StorySection("Anchored form", "The overlay escapes clipping and repositions near viewport edges.") {
            Popover(isPresented: $open, isEnabled: options.isEnabled, width: 300, label: {
                Row(alignment: .center, spacing: 6) { Text("Project settings"); Icon(UICommonIcons.chevronDown, size: 12) }
            }, content: {
                Box(direction: .column, alignItems: .stretch, spacing: 12) {
                    Text("Project name").font(.bodyStrong)
                    TextField("Name", text: $name)
                    Button("Done") { open = false }
                }.padding(16).background(.surfaceFloating).cornerRadius(8).border(.border, width: 1)
            })
            Text("Name: \(name.stringValue)").font(.caption).foregroundColor(.onSurfaceMuted)
        }
    }
}

struct ModalStory: View {
    let options: GalleryOptions
    @State private var open = false
    @State private var status = "No changes"
    @State private var name: TextBuffer = "Untitled"
    var body: some View {
        StorySection("Dialog", "Open the dialog, cycle focus with Tab, then close with Escape or the cancel action.") {
            Button("Create project", isEnabled: options.isEnabled) { open = true }.debugName("gallery-open-modal")
            Text(status).font(.caption).foregroundColor(.onSurfaceMuted)
            Modal(isPresented: $open, configure: { $0.geometry.width = 440; $0.geometry.height = 220 }) {
                Box(direction: .column, alignItems: .stretch, spacing: 14) {
                    Text("Create project").font(.headline)
                    TextField("Project name", text: $name)
                    Spacer()
                    Row(alignment: .center, spacing: 10) {
                        Spacer()
                        Button("Cancel", role: .cancel) { open = false }.buttonStyle(.secondary)
                        Button("Create") { status = "Created \(name.stringValue)"; open = false }
                    }
                }.padding(24)
            }
        }
    }
}

struct DisclosureStory: View {
    let options: GalleryOptions
    @State private var expanded = true
    @State private var text: TextBuffer = "The draft survives collapse"
    var body: some View {
        StorySection("Collapsible content", "Expansion is caller-owned, so search and Expand All can control it.") {
            DisclosureGroup("Project details", isExpanded: $expanded, isEnabled: options.isEnabled) {
                TextField("Description", text: $text).padding(8)
            }
            DisclosureGroup("Disabled section", isExpanded: .constant(false), isEnabled: false) { Text("Hidden") }
        }
    }
}

struct TabsStory: View {
    @State private var selection = "overview"
    var body: some View {
        StorySection("Content tabs", "Arrow keys wrap among enabled tabs and move actual focus. Home and End choose the edges.") {
            TabView(selection: $selection, tabs: [
                TabItem("Overview", id: "overview") { Text("Project overview").padding(20) },
                TabItem("Unavailable", id: "disabled", isEnabled: false) { Text("Disabled content") },
                TabItem("Activity", id: "activity") { Text("Recent activity").padding(20) },
                TabItem("Settings", id: "settings") { Text("Project settings").padding(20) }
            ]).frame(height: 220)
            Text("Active tab: \(selection)").font(.caption).foregroundColor(.onSurfaceMuted)
        }
    }
}
