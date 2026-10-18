import GuavaUI
import GuavaUIRuntime

struct ActionSheetStory: View {
    let options: GalleryOptions
    @State private var open = false
    @State private var manyOpen = false
    @State private var lastAction = "None"
    @State private var exportEnabled = false

    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 24) {
            StorySection("Project actions", "A bottom drawer at every width. Compact surfaces dismiss from the drag handle or outside tap; wider drawers use a caller-localized top close control.") {
                ThemeReader { theme in
                    Box(direction: .row, justifyContent: .center) {
                        Box(direction: .column, alignItems: .stretch, spacing: 18) {
                            Box(direction: .row, alignItems: .center, spacing: 12) {
                                Icon(UIIcons.File.folder, size: 26, color: .accent)
                                    .padding(10).background(.surfaceVariant).cornerRadius(12)
                                Column(alignment: .leading, spacing: 4) {
                                    Text("Aurora project").font(.bodyStrong)
                                    Text("Last edited a few minutes ago").font(.caption).foregroundColor(.onSurfaceMuted)
                                }.frame(minWidth: 0).flex(1, shrink: 1, basis: 0)
                                Badge("Draft") { $0.tone = .neutral }
                            }
                            Text("Keep related commands together, with a clear way to back out.")
                                .foregroundColor(.onSurfaceVariant)
                            ActionSheet(isPresented: $open, title: "Aurora project", message: "Choose an action for this project.",
                                actions: projectActions, closeLabel: "Close project actions",
                                isEnabled: options.isEnabled) {
                                Row(alignment: .center, spacing: 8) {
                                    Icon(UIIcons.Action.moreHorizontal, size: .small)
                                    Text("Project actions")
                                }
                            }.debugName("gallery-action-sheet")
                        }.padding(20).background(.surface).cornerRadius(theme.radius.lg).border(.border, width: 1)
                            .frame(width: .percent(100), maxWidth: 520)
                    }
                }
                Box(direction: .row, alignItems: .center, wrap: .wrap, spacing: 8) {
                    Checkbox(isOn: $exportEnabled, isEnabled: options.isEnabled).accessibilityLabel("Enable export")
                    Text("Export available").font(.caption).foregroundColor(.onSurfaceMuted)
                    Spacer()
                    Text("Last action: \(lastAction)").font(.caption).foregroundColor(.onSurfaceMuted)
                }
            }
            StorySection("Long action lists", "Arrow keys skip unavailable actions. Home and End move to the edges; the header and close control stay outside the scrolling list.") {
                ActionSheet(isPresented: $manyOpen, title: "Workspace shortcuts",
                    message: "The list scrolls while the close control remains visible.",
                    actions: (1...24).map { index in
                        ActionSheetAction("shortcut-\(index)", "Workspace shortcut \(index)") { lastAction = "Shortcut \(index)" }
                    }, closeLabel: "Close workspace actions", isEnabled: options.isEnabled) {
                    Text("Browse workspace actions")
                }
            }
        }
    }

    private var projectActions: [ActionSheetAction] {
        [ActionSheetAction("duplicate", "Duplicate project", icon: UIIcons.Action.copy) { lastAction = "Duplicated" },
         ActionSheetAction("archive", "Archive project", icon: UIIcons.File.archive) { lastAction = "Archived" },
         ActionSheetAction("export", "Export project", icon: UIIcons.Action.download, isEnabled: exportEnabled) { lastAction = "Exported" },
         ActionSheetAction("delete", "Delete project", icon: UIIcons.Action.trash, role: .destructive) { lastAction = "Deleted" }]
    }
}

struct ActionSheetPreview: View {
    let isEnabled: Bool
    @State private var open = false
    var body: some View {
        ActionSheet(isPresented: $open, title: "Preview actions",
            actions: [ActionSheetAction("duplicate", "Duplicate") {}, ActionSheetAction("delete", "Delete", role: .destructive) {}],
            closeLabel: "Close preview actions", isEnabled: isEnabled) { Text("Preview actions") }
    }
}
