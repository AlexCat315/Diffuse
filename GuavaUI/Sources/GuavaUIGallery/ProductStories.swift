import GuavaUICompose
import GuavaUIRuntime

struct RadioStory: View {
    let options: GalleryOptions
    @State private var mode: String? = "balanced"
    var body: some View {
        StorySection("Performance preference", "Tab enters once. Arrows choose an enabled option and move focus; the disabled option is skipped.") {
            RadioGroup(selection: $mode, options: [
                RadioOption("fast", "Fast") { $0.detail = "Prefer lower latency" },
                RadioOption("balanced", "Balanced") { $0.detail = "Balance quality and speed" },
                RadioOption("offline", "Unavailable") { $0.isEnabled = false },
                RadioOption("quality", "High quality")
            ]) { $0.isEnabled = options.isEnabled }
            Text("Selected: \(mode ?? "None")").font(.caption).foregroundColor(.onSurfaceMuted)
        }
    }
}

struct FormStory: View {
    let options: GalleryOptions
    @State private var name: TextBuffer = ""
    @State private var email: TextBuffer = ""
    @State private var controller = FormController()
    @State private var status = "Complete the required fields"
    var rules: [FormRule] {
        [FormRule.required("name", label: "Name", value: { name.stringValue }),
         FormRule("email", label: "Email") { email.stringValue.contains("@") && email.stringValue.contains(".") ? nil : "Enter a valid email address." }]
    }
    var body: some View {
        StorySection("Create an account", "Submit an empty form to see field errors and the summary. Values stay intact when validation resets.") {
            Form([
                FormField("name", "Name", configure: { $0.isRequired = true; $0.help = "Your visible display name" }) {
                    TextField("Your name", text: $name) { $0.behavior.disabled = !options.isEnabled }
                },
                FormField("email", "Email", configure: { $0.isRequired = true }) {
                    TextField("hello@example.com", text: $email) { $0.behavior.disabled = !options.isEnabled }
                }
            ], controller: controller) {
                Button("Reset validation") { controller.reset(); status = "Validation reset" }.buttonStyle(.ghost)
                Button("Submit", isEnabled: options.isEnabled, isLoading: controller.isSubmitting) {
                    if controller.beginSubmit(rules) { controller.finishSubmit(); status = "Saved account for \(name.stringValue)" }
                    else { status = "Check the highlighted fields" }
                }.debugName("gallery-form-submit")
            }.frame(width: 520)
            Text(status).font(.caption).foregroundColor(.onSurfaceMuted)
        }
    }
}

struct ComboboxStory: View {
    let options: GalleryOptions
    @State private var city: String? = nil
    var body: some View {
        StorySection("Searchable selection", "Search in English or Chinese, use Up/Down and Return, or clear the selection. Unavailable options cannot be chosen.") {
            Combobox(selection: $city, options: [
                SelectOption(value: "beijing", label: "北京 · Beijing"), SelectOption(value: "shanghai", label: "上海 · Shanghai"),
                SelectOption(value: "hongkong", label: "香港 · Hong Kong"), SelectOption(value: "london", label: "London"),
                SelectOption(value: "unavailable", label: "Unavailable", isEnabled: false)
            ]) { $0.isEnabled = options.isEnabled; $0.placeholder = "Choose a city" }
            Text("Selected: \(city ?? "None")").font(.caption).foregroundColor(.onSurfaceMuted)
        }
    }
}

struct NotificationStory: View {
    @State private var controller = ToastController(maxVisible: 3)
    @State private var count = 0
    var body: some View {
        StorySection("Toast queue", "Notifications appear at the window edge. Hover pauses expiry. Add several to see the bounded queue, or replace the same stable ID.") {
            Row(alignment: .center, spacing: 10) {
                Button("Notify") {
                    count += 1
                    controller.post(ToastNotification("Project saved · \(count)") { $0.tone = .success; $0.message = "Your changes are available." })
                }
                Button("Replace status") {
                    count += 1
                    controller.post(ToastNotification("Import status · \(count)", id: "import") { $0.message = "This status replaces the previous import notification." })
                }.buttonStyle(.secondary)
                Button("Persistent warning") { controller.post(ToastNotification("Action required", id: "warning") { $0.duration = nil; $0.tone = .warning; $0.message = "Dismiss this notification when you have read it." }) }.buttonStyle(.warning)
                Button("Clear") { controller.clear() }.buttonStyle(.ghost)
            }
            Text("Visible: \(controller.notifications.count) · Queued: \(controller.queuedCount)").font(.caption).foregroundColor(.onSurfaceMuted)
            NotificationHost(controller)
        }
    }
}

struct TooltipStory: View {
    var body: some View {
        StorySection("Managed descriptions", "Rest the pointer on a target or focus the button with Tab. The description stays outside its clipping parent.") {
            Row(alignment: .center, spacing: 18) {
                Button("Save") {}.tooltip("Save the current project. Keyboard focus also reveals this description.")
                Badge("Hover over text", tone: .info).tooltip("Any view can be a tooltip target.")
            }
            Box { Text("Clipped target").font(.body).padding(12).tooltip("This description uses the window's overlay layer.") }
                .frame(width: 180, height: 50).clipped().border(.border, width: 1)
        }
    }
}

struct SidebarStory: View {
    @State private var selection: String? = "projects"
    var body: some View {
        StorySection("Grouped navigation", "The same public Sidebar powers this component gallery. Tab enters the destination group once; arrows select and move focus.") {
            Sidebar(selection: $selection, sections: [
                SidebarSection("workspace", title: "Workspace", items: [SidebarItem("projects", "Projects") { $0.badge = "8" }, SidebarItem("recent", "Recent")]),
                SidebarSection("settings", title: "Settings", items: [SidebarItem("general", "General"), SidebarItem("unavailable", "Unavailable") { $0.isEnabled = false }])
            ], header: { Text("My workspace").font(.bodyStrong).padding(14) },
               footer: { Text("Connected").font(.caption).foregroundColor(.success).padding(14) })
                .frame(width: 260, height: 360).border(.border, width: 1)
            Text("Destination: \(selection ?? "None")").font(.caption).foregroundColor(.onSurfaceMuted)
        }
    }
}
