import GuavaUICompose
import GuavaUIRuntime

struct AccordionStory: View {
    let options: GalleryOptions
    @State private var expanded: Set<String> = ["overview"]
    @State private var multiple = false
    var body: some View {
        StorySection("Grouped disclosures", "Arrows move between headers. Return or Space expands a section. Switching the mode changes whether several sections may remain open.") {
            Row(alignment: .center, spacing: 8) { Checkbox(isOn: $multiple); Text("Allow multiple sections").font(.caption) }
            Accordion([
                AccordionItem("overview", "Overview") { Text("Authored expansion is owned by the caller.").font(.body) },
                AccordionItem("details", "Details") { Text("Expanded content uses the shared visibility and focus lifecycle.").font(.body) },
                AccordionItem("unavailable", "Unavailable", isEnabled: false) { EmptyView() }
            ], expanded: $expanded) { $0.allowsMultiple = multiple; $0.isEnabled = options.isEnabled }.frame(width: 520)
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
    var body: some View {
        StorySection("Removable tags", "Each remove action is an independent control. Reset restores the tags.") {
            Row(alignment: .center, spacing: 8) {
                for title in tags {
                    AnyView(Tag(title) { $0.tone = .info; $0.isEnabled = options.isEnabled; $0.onRemove = { tags.removeAll { $0 == title } } })
                }
            }
            if tags.isEmpty { Text("No tags selected").font(.caption).foregroundColor(.onSurfaceMuted) }
        }
    }
}
struct KeyCapStory: View {
    var body: some View {
        StorySection("Keyboard hints", "Platform-aware shortcut text uses the same formatter as command menus.") {
            Row(alignment: .center, spacing: 12) { KeyCap(.primary("S")); Text("Save").font(.label); KeyCap("Esc"); Text("Dismiss").font(.label); KeyCap("↑ ↓"); Text("Navigate").font(.label) }
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
