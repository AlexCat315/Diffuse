import GuavaUI
import GuavaUIRuntime

struct AccordionStory: View {
    let options: GalleryOptions
    @State private var expanded: Set<String> = ["project"]
    @State private var multiple = false
    @State private var reduceMotion = false
    @State private var project: TextBuffer = "Guava Studio"
    @State private var autosave = true
    @State private var diagnostics = false
    var body: some View {
        StorySection("Project preferences", "Up / Down and Home / End move between headers. Return or Space expands a section. Try reversing an animation or changing the scale while it is open.") {
            Box(direction: .row, alignItems: .center, wrap: .wrap, spacing: 12) {
                Row(alignment: .center, spacing: 8) {
                    Checkbox(isOn: Binding(get: { multiple }, set: {
                        multiple = $0
                        if !$0 && expanded.count > 1 { expanded = ["project"] }
                    }), isEnabled: options.isEnabled).debugName("accordion-multiple")
                    Text("Multiple sections").font(.caption)
                }
                Row(alignment: .center, spacing: 8) {
                    Checkbox(isOn: $reduceMotion, isEnabled: options.isEnabled).debugName("accordion-reduced-motion")
                    Text("Reduce motion").font(.caption)
                }
                Button(expanded.isEmpty ? "Open project" : "Collapse all", isEnabled: options.isEnabled) {
                    expanded = expanded.isEmpty ? ["project"] : []
                }.buttonStyle(.ghost).debugName("accordion-collapse-all")
            }
            Accordion([
                AccordionItem("project", "Project") {
                    Box(direction: .column, alignItems: .stretch, spacing: 12) {
                        Text("Keep the project name and preferences together. Editing stays caller-owned when a section closes.")
                            .foregroundColor(.onSurfaceMuted)
                        TextField("Project name", text: $project) { $0.behavior.disabled = !options.isEnabled }
                            .debugName("accordion-project-name")
                        Row(alignment: .center, spacing: 10) {
                            Checkbox(isOn: $autosave, isEnabled: options.isEnabled)
                            Text("Save changes automatically")
                        }
                    }
                },
                AccordionItem("diagnostics", "Diagnostics & activity") {
                    Box(direction: .column, alignItems: .stretch, spacing: 12) {
                        Row(alignment: .center, spacing: 10) {
                            Checkbox(isOn: $diagnostics, isEnabled: options.isEnabled).debugName("accordion-diagnostics")
                            Text("Include diagnostic details")
                        }
                        Text(diagnostics ? "Verbose diagnostics enabled. Render timing and asset events appear in the project log." : "Only warnings and errors are recorded.")
                            .foregroundColor(.onSurfaceMuted)
                        Alert("Everything is up to date", message: "Your project has no pending imports.", tone: .success)
                    }
                },
                AccordionItem("unavailable", "Team permissions · unavailable", isEnabled: false) { EmptyView() }
            ], expanded: $expanded) {
                $0.allowsMultiple = multiple; $0.isEnabled = options.isEnabled
            }.reducedMotion(reduceMotion).frame(minWidth: 0, maxWidth: 680).debugName("accordion-preview")
            Text("\(expanded.count) sections open · \(autosave ? "Autosave on" : "Autosave off")")
                .font(.caption).foregroundColor(.onSurfaceMuted)
        }
    }
}
struct BreadcrumbStory: View {
    @State private var selected = "Project"
    var body: some View {
        StorySection("Path navigation", "Long paths collapse intermediate destinations into a menu; the current destination remains a label.") {
            Breadcrumb([BreadcrumbItem("home", "Home"), BreadcrumbItem("team", "Team"), BreadcrumbItem("project", "Project"),
                        BreadcrumbItem("assets", "Assets"), BreadcrumbItem("textures", "Textures"), BreadcrumbItem("selected", "Guava.png")]) { selected = $0 }
            Text("Opened: \(selected)").font(.caption).foregroundColor(.onSurfaceMuted)
        }
    }
}
struct PaginationStory: View {
    let options: GalleryOptions
    @State private var page = 8
    var body: some View {
        StorySection("Navigate pages", "Only nearby pages are shown. Boundary actions disable themselves, and empty datasets expose no invalid page number.") {
            Pagination(page: $page, totalPages: 25) { $0.isEnabled = options.isEnabled }
            Text("Page \(page) of 25").font(.caption).foregroundColor(.onSurfaceMuted)
            Pagination(page: .constant(0), totalPages: 0)
        }
    }
}
struct ButtonGroupStory: View {
    let options: GalleryOptions
    @State private var mode: String? = "grid"
    var body: some View {
        StorySection("View preference", "The selected segment is caller-owned. The group has one Tab stop; arrows skip the unavailable segment.") {
            ButtonGroup([ButtonGroupItem("grid", "Grid"), ButtonGroupItem("list", "List"), ButtonGroupItem("map", "Map", isEnabled: false)], selection: $mode, isEnabled: options.isEnabled)
            Text("Mode: \(mode ?? "None")").font(.caption).foregroundColor(.onSurfaceMuted)
        }
    }
}
struct TagStory: View {
    let options: GalleryOptions
    @State private var tags = ["Swift", "Rendering", "Editor"]
    @State private var filters = ["metal", "vulkan"]
    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 24) {
            StorySection("Removable tags", "Each remove action is an independent control. Reset restores the tags.") {
                Row(alignment: .center, spacing: 8) {
                    for title in tags {
                        AnyView(Tag(title) { $0.tone = .info; $0.isEnabled = options.isEnabled; $0.onRemove = { tags.removeAll { $0 == title } } })
                    }
                }
                if tags.isEmpty { Text("No tags selected").font(.caption).foregroundColor(.onSurfaceMuted) }
            }
            StorySection("Variants & glyphs", "Soft reads inside dense content; solid is a single callout; outline sits beside an already-bordered surface.") {
                Row(alignment: .center, spacing: 8) {
                    Tag("metal") { $0.variant = .soft; $0.isEnabled = options.isEnabled }
                    Tag("vulkan") { $0.variant = .solid; $0.tone = .info; $0.isEnabled = options.isEnabled }
                    Tag("deprecated") { $0.variant = .outline; $0.tone = .warning; $0.isEnabled = options.isEnabled }
                    Tag("renderer") { $0.icon = UIIcons.Editor.box; $0.variant = .outline; $0.isEnabled = options.isEnabled }
                    Tag("3 failures") { $0.showsDot = true; $0.tone = .danger; $0.isEnabled = options.isEnabled }
                }
                Row(alignment: .center, spacing: 8) {
                    for title in filters {
                        AnyView(Tag(title) { $0.variant = .outline; $0.isEnabled = options.isEnabled; $0.onRemove = { filters.removeAll { $0 == title } } })
                    }
                }
            }
        }
    }
}

struct KeyCapStory: View {
    var body: some View {
        StorySection("Keyboard hints", "Platform-aware shortcut text uses the same formatter as command menus.") {
            Column(alignment: .leading, spacing: 10) {
                Row(alignment: .center, spacing: 12) { KeyCap(.primary("S")); Text("Save").font(.label) }
                Row(alignment: .center, spacing: 12) { KeyCap(.primaryShift("P")); Text("Command palette").font(.label) }
                Row(alignment: .center, spacing: 12) { KeyCap(.primary("K"), platform: .windows); Text("Same shortcut on Windows").font(.label) }
                Row(alignment: .center, spacing: 12) { KeyCap("Esc"); Text("Dismiss").font(.label) }
                Row(alignment: .center, spacing: 12) { KeyCap(["↑", "↓"]); Text("Navigate").font(.label) }
                Row(alignment: .center, spacing: 12) { KeyCap("⏎") { $0.isEnabled = false }; Text("Disabled hint").font(.label) }
            }
        }
    }
}
struct LabelStory: View {
    @State private var name: TextBuffer = ""
    var body: some View {
        StorySection("Associated field labels", "Click the label to focus its input. The system receives the field name, required state and helper description.") {
            Form([FormField("display-name", "Display name", configure: { $0.isRequired = true; $0.help = "Visible to your teammates" }) {
                TextField("Enter a name", text: $name)
            }]).frame(width: 360)
        }
    }
}
struct DialogStory: View {
    @State private var open = false
    @State private var name: TextBuffer = "Guava"
    var body: some View {
        StorySection("Structured dialog", "Header, scrollable content and actions share the modal focus and dismissal policy.") {
            Button("Edit profile") { open = true }
            Dialog(isPresented: $open, title: "Edit profile", configure: { $0.description = "Update your display name"; $0.modal.geometry.width = 460; $0.modal.geometry.height = 280 }) {
                Form([FormField("profile-name", "Name") { TextField("Name", text: $name) }])
            } footer: {
                Button("Cancel") { open = false }.buttonStyle(.secondary)
                Button("Save") { open = false }
            }
            Text("Name: \(name.stringValue)").font(.caption).foregroundColor(.onSurfaceMuted)
        }
    }
}
struct AlertDialogStory: View {
    @State private var open = false
    @State private var deleted = false
    var body: some View {
        StorySection("Confirm a destructive action", "The example only changes local state. Confirmation and cancellation have distinct visual roles.") {
            Button("Delete example", role: .destructive) { open = true }
            AlertDialog(isPresented: $open, title: "Delete example?", message: "This removes the example from this local preview.", configure: {
                $0.isDestructive = true; $0.confirmTitle = "Delete"
            }) { deleted = true }
            Text(deleted ? "Example deleted" : "Example available").font(.caption).foregroundColor(.onSurfaceMuted)
        }
    }
}
struct SheetStory: View {
    let options: GalleryOptions
    @State private var open = false
    @State private var setting = true
    @State private var edge: ModalPlacement = .trailing
    var body: some View {
        StorySection("Edge sheets", "Each panel enters and leaves through its chosen edge, with modal focus confinement and restoration.") {
            Row(spacing: 8) {
                Button("Leading", isEnabled: options.isEnabled) { edge = .leading; open = true }
                Button("Trailing", isEnabled: options.isEnabled) { edge = .trailing; open = true }
                Button("Top", isEnabled: options.isEnabled) { edge = .top; open = true }
                Button("Bottom", isEnabled: options.isEnabled) { edge = .bottom; open = true }
            }
            Sheet(isPresented: $open, configure: { $0.edge = edge; $0.extent = 320 }) {
                Box(direction: .column, alignItems: .stretch, spacing: 16) {
                    Row(alignment: .center) { Text("Project settings").font(.headline); Spacer(); Button("Close") { open = false }.buttonStyle(.ghost) }
                    Divider()
                    Row(alignment: .center, spacing: 12) { Toggle(isOn: $setting).accessibilityLabel("Auto-save"); Text("Auto-save").font(.body) }
                    Spacer()
                    Row { Spacer(); Button("Done") { open = false } }
                }.padding(24)
            }
        }
    }
}

struct BottomSheetStory: View {
    let options: GalleryOptions
    @State private var open = false
    @State private var notifications = true

    var body: some View {
        StorySection("Bottom sheet", "Open the sheet, then drag its handle up for the larger detent or down to dismiss. On wide surfaces it degrades to a centered dialog-sized panel; Escape and the backdrop still dismiss through the modal contract.") {
            Button("Open bottom sheet", isEnabled: options.isEnabled) { open = true }
            BottomSheet(isPresented: $open, configure: {
                $0.detents = [280, 480]
                $0.initialDetent = 0
                $0.dragDismissThreshold = 70
            }) {
                Box(direction: .column, alignItems: .stretch, spacing: 14) {
                    Text("Quick actions").font(.headline)
                    Text("Drag the handle up for more space, or down to close.").font(.caption).foregroundColor(.onSurfaceMuted)
                    Divider()
                    Row(alignment: .center, spacing: 12) {
                        Toggle(isOn: $notifications, isEnabled: options.isEnabled)
                        Text("Notifications").font(.body)
                    }
                    Spacer()
                    Row(alignment: .center, spacing: 8) {
                        Spacer()
                        Button("Close") { open = false }.buttonStyle(.secondary)
                    }
                }.padding(20)
            }
        }
    }
}
