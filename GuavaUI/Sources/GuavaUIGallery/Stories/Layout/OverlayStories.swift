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
                Row(alignment: .center, spacing: 8) { Text("Workspace commands").font(.body); Icon(UIIcons.Navigation.chevronDown, size: 12) }
            } content: { Menu(entries, width: 260, onItemActivated: { open = false }) }
            Text(status).font(.caption).foregroundColor(.onSurfaceMuted)
        }
        StorySection("Inline menu", "Shared selection columns, labels, separators, disabled actions and destructive color. Submenus escape the card's clipping.") {
            Menu(entries, width: 260)
        }
        StorySection("Scrollable menu", "100 commands with nested branches. Keyboard navigation reveals the active row; a child closes when its anchor scrolls away.") {
            Popover(isPresented: $manyOpen, isEnabled: options.isEnabled, width: 240) {
                Row(alignment: .center, spacing: 8) { Text("100 commands").font(.body); Icon(UIIcons.Navigation.chevronDown, size: 12) }
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
                Row(alignment: .center, spacing: 6) { Text("Project settings"); Icon(UIIcons.Navigation.chevronDown, size: 12) }
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
    @State private var segment = "day"
    @State private var documents = ["Scene.guava", "Material.guava", "Notes.md"]
    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 24) {
            StorySection("Content tabs", "Arrow keys wrap among enabled tabs and move actual focus. Home and End choose the edges.") {
                TabView(selection: $selection, tabs: [
                    TabItem("Overview", id: "overview") { $0.icon = UIIcons.File.file } content: { Text("Project overview").padding(20) },
                    TabItem("Unavailable", id: "disabled", isEnabled: false) { Text("Disabled content") },
                    TabItem("Activity", id: "activity") { $0.icon = UIIcons.Data.activity; $0.badge = "3" } content: { Text("Recent activity").padding(20) },
                    TabItem("Settings", id: "settings") { $0.icon = UIIcons.Action.settings } content: { Text("Project settings").padding(20) }
                ]).frame(height: 220)
                Text("Active tab: \(selection)").font(.caption).foregroundColor(.onSurfaceMuted)
            }
            StorySection("Variants", "A segmented strip picks a value; a card strip keeps folder semantics; both use the same items.") {
                TabView(selection: $segment, tabs: [
                    TabItem("Day", id: "day") { Text("Day view").padding(16) },
                    TabItem("Week", id: "week") { Text("Week view").padding(16) },
                    TabItem("Month", id: "month") { Text("Month view").padding(16) }
                ]) { $0.variant = .segmented }
                TabView(selection: $segment, tabs: [
                    TabItem("Day", id: "day") { Text("Day view").padding(16) },
                    TabItem("Week", id: "week") { Text("Week view").padding(16) },
                    TabItem("Month", id: "month") { Text("Month view").padding(16) }
                ]) { $0.variant = .card }.frame(height: 120)
            }
            StorySection("Closable tabs", "A tab with a close action renders its own close control; closing falls back to the nearest remaining tab.") {
                TabView(selection: .constant("Scene.guava"), tabs: documents.map { name in
                    TabItem(name, id: name) { $0.icon = UIIcons.File.fileText; $0.onClose = { documents.removeAll { $0 == name } } } content: { Text("Editing \(name)").padding(20) }
                }).frame(height: 160)
                if documents.isEmpty { Text("All documents closed — reset the example to restore them.").font(.caption).foregroundColor(.onSurfaceMuted) }
            }
        }
    }
}

struct CommandPaletteStory: View {
    @State private var isPresented = false
    @State private var lastRun = "none"

    private var items: [CommandItem] {
        [
            CommandItem("Toggle Theme", group: "View", keywords: ["dark", "light", "appearance"],
                        icon: UIIcons.Device.moon, shortcut: .primaryShift("L")) { lastRun = "Toggle Theme" },
            CommandItem("Go to File", group: "Navigate", keywords: ["jump", "search"],
                        icon: UIIcons.File.folderOpen, shortcut: .primary("P")) { lastRun = "Go to File" },
            CommandItem("Go to Line", group: "Navigate", keywords: ["jump"],
                        icon: UIIcons.Editor.code, shortcut: .primary("G")) { lastRun = "Go to Line" },
            CommandItem("Format Document", group: "Edit", keywords: ["pretty", "reindent"],
                        icon: UIIcons.Action.format, shortcut: .primaryShift("F")) { lastRun = "Format Document" },
            CommandItem("Rename Symbol", group: "Edit", keywords: ["refactor"],
                        icon: UIIcons.Action.pencil) { lastRun = "Rename Symbol" },
            CommandItem("Run Build", group: "Build", keywords: ["compile"],
                        icon: UIIcons.Editor.hammer, shortcut: .primary("B")) { lastRun = "Run Build" },
            CommandItem("Clean Build Folder", group: "Build", keywords: ["wipe"],
                        icon: UIIcons.Action.trash) { lastRun = "Clean Build Folder" },
            CommandItem("Deploy to Device", group: "Build", keywords: ["ship"],
                        icon: UIIcons.File.package, isEnabled: false) { lastRun = "Deploy to Device" }
        ]
    }

    var body: some View {
        StorySection("Command palette", "Open it and type a fragment such as “go f” or “theme”. Up and Down move the highlight, Return runs it, Escape closes.") {
            Row(alignment: .center, spacing: 12) {
                Button("Open command palette") { isPresented = true }
                KeyCap(.primaryShift("P"))
                Text("Last run: \(lastRun)").font(.caption).foregroundColor(.onSurfaceMuted)
            }
            CommandPalette(isPresented: $isPresented, items: items)
        }
    }
}

struct HoverCardStory: View {
    var body: some View {
        StorySection("Hover card", "Rest the pointer on a name to read its detail. The card opens after a short delay and stays open while the pointer is over it.") {
            Column(alignment: .leading, spacing: 12) {
                HoverCard(width: 320, label: {
                    Text("@ada").font(.bodyStrong).foregroundColor(.accent)
                }) {
                    Column(alignment: .leading, spacing: 6) {
                        Text("Ada Lovelace").font(.bodyStrong)
                        Text("Analytical Engine · contributor since 1843").font(.caption).foregroundColor(.onSurfaceMuted)
                        Row(alignment: .center, spacing: 6) {
                            Badge("Maintainer", tone: .success)
                            Badge("Offline", tone: .neutral)
                        }
                    }
                }
                HoverCard(width: 300, label: {
                    Row(alignment: .center, spacing: 6) {
                        Icon(UIIcons.Editor.box, size: 14, color: .onSurfaceMuted)
                        Text("MeshRenderer").font(.bodyStrong)
                    }
                }) {
                    Column(alignment: .leading, spacing: 6) {
                        Text("Renders a mesh with a material").font(.body)
                        Text("Costs one draw call per submesh.").font(.caption).foregroundColor(.onSurfaceMuted)
                    }
                }
                Text("Hover cards are a pointer affordance — the same detail must be reachable another way.").font(.caption).foregroundColor(.onSurfaceMuted)
            }
        }
    }
}

struct ToolbarStory: View {
    let options: GalleryOptions
    @State private var isPlaying = false
    @State private var isBold = true
    var body: some View {
        StorySection("Toolbar", "One height, one spacing rhythm, and separators between groups — the bar owns the frame so every toolbar lines up.") {
            Toolbar {
                ToolbarGroup {
                    Button(icon: .resource(UIIcons.Editor.play), isEnabled: options.isEnabled, isSelected: isPlaying, tooltip: "Play", action: { isPlaying = true })
                    Button(icon: .resource(UIIcons.Editor.stop), isEnabled: options.isEnabled, isSelected: !isPlaying, tooltip: "Stop", action: { isPlaying = false })
                }
                ToolbarSeparator()
                ToolbarGroup(isBordered: true) {
                    Button(icon: .resource(UIIcons.Text.bold), isEnabled: options.isEnabled, isSelected: isBold, tooltip: "Bold", action: { isBold.toggle() })
                    Button(icon: .resource(UIIcons.Text.italic), isEnabled: options.isEnabled, tooltip: "Italic", action: {})
                }
                Spacer()
                ToolbarGroup {
                    Button(icon: .resource(UIIcons.Action.zoomOut), isEnabled: options.isEnabled, tooltip: "Zoom out", action: {})
                    Button(icon: .resource(UIIcons.Action.zoomIn), isEnabled: options.isEnabled, tooltip: "Zoom in", action: {})
                }
            }
            Toolbar { $0.divider = .top } content: {
                Text("A bar below its content puts the divider on top.").font(.caption).foregroundColor(.onSurfaceMuted)
                Spacer()
                Button("Apply", isEnabled: options.isEnabled) {}
            }
        }
    }
}
