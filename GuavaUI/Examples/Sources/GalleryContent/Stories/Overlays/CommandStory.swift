import GuavaUI
import GuavaUIRuntime

struct CommandPaletteStory: View {
    let options: GalleryOptions
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
        StorySection("Command palette", "Try “GO”, “go f” or “appearance”. Arrows move, Page Up/Down jump, Return runs and Escape closes. Disabled commands are skipped; run one and reopen to see it under Recent.") {
            Row(alignment: .center, spacing: 12) {
                Button("Open command palette", isEnabled: options.isEnabled) { isPresented = true }
                    .debugName("command-open")
                KeyCap(.primaryShift("P"))
                Text("Last run: \(lastRun)").font(.caption).foregroundColor(.onSurfaceMuted)
            }
            ShortcutHost(onKeyDown: { event in
                guard options.isEnabled, !event.isRepeat, event.scancode == Scancode.p,
                      event.modifiers.hasShift, event.modifiers.hasGui || event.modifiers.hasCtrl else { return false }
                isPresented = true; return true
            })
            CommandPalette(isPresented: $isPresented, items: items)
        }
    }
}
