import GuavaUI
import GuavaUIRuntime

struct PopconfirmStory: View {
    let options: GalleryOptions
    @State private var lastAction = "None"
    @State private var enabled = true

    var body: some View {
        StorySection(
            "Anchored confirmation",
            "The trigger is a real button; the popover owns focus, Escape and outside dismissal. Destructive actions require the explicit red confirm button."
        ) {
            ThemeReader { theme in
                Box(direction: .column, alignItems: .stretch, spacing: 10) {
                    Box(direction: .row, alignItems: .center, justifyContent: .spaceBetween, wrap: .wrap, spacing: 12) {
                        Row(alignment: .center, spacing: 10) {
                            Icon(UIIcons.Action.trash, size: .small, color: .error)
                            Column(alignment: .leading, spacing: 2) {
                                Text("Delete project").font(.bodyStrong)
                                Text("This removes the project and its local history.").font(.caption).foregroundColor(.onSurfaceMuted)
                            }.flex(1, shrink: 1, basis: 0).frame(minWidth: 0)
                        }.flex(1, shrink: 1, basis: 200).frame(minWidth: 0)
                        Popconfirm(
                            "Delete",
                            icon: UIIcons.Action.trash,
                            title: "Delete “Archived mockup”?",
                            message: "This action cannot be undone. The project and its local history will be removed.",
                            confirmTitle: "Delete",
                            role: .destructive,
                            isEnabled: options.isEnabled && enabled
                        ) {
                            lastAction = "Deleted"
                        }
                    }
                    Box(direction: .row, alignItems: .center, justifyContent: .spaceBetween, wrap: .wrap, spacing: 12) {
                        Row(alignment: .center, spacing: 10) {
                            Icon(UIIcons.File.archive, size: .small, color: .onSurfaceMuted)
                            Column(alignment: .leading, spacing: 2) {
                                Text("Archive project").font(.bodyStrong)
                                Text("Keeps the project; it can be restored later.").font(.caption).foregroundColor(.onSurfaceMuted)
                            }.flex(1, shrink: 1, basis: 0).frame(minWidth: 0)
                        }.flex(1, shrink: 1, basis: 200).frame(minWidth: 0)
                        Popconfirm(
                            "Archive",
                            title: "Archive this project?",
                            message: "You can restore it from the archive at any time.",
                            confirmTitle: "Archive",
                            isEnabled: options.isEnabled && enabled
                        ) {
                            lastAction = "Archived"
                        }
                    }
                }
                .padding(14)
                .background(.surface)
                .border(.border, width: 1)
                .cornerRadius(theme.radius.md)
            }
            Box(direction: .row, alignItems: .center, wrap: .wrap, spacing: 8) {
                Checkbox(isOn: $enabled, isEnabled: options.isEnabled)
                    .accessibilityLabel("Enable confirmation actions")
                Text("Enabled").font(.caption).foregroundColor(.onSurfaceMuted)
                Text("Last action: \(lastAction)").font(.caption).foregroundColor(.onSurfaceMuted)
                    .debugName("popconfirm-last-action")
                Box {}.flex(1)
            }
            Text("Cancel or Escape closes the bubble without invoking the action. The destructive trigger is styled separately from the confirm button.")
                .font(.caption).foregroundColor(.onSurfaceMuted)

            PopoverPlacementExample(options: options) { lastAction = $0 }
        }
    }
}
