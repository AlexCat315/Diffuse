import GuavaUI
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
        StorySection("Create an account", "Labels move above their inputs when space is limited. Resize or change text scale while editing; drafts and focus stay intact. Submit to see field errors.") {
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
            }.frame(maxWidth: 720)
            Text(status).font(.caption).foregroundColor(.onSurfaceMuted)
        }
    }
}

struct ComboboxStory: View {
    let options: GalleryOptions
    @State private var city: String? = "shanghai"
    var body: some View {
        StorySection("Searchable selection", "Search in English or Chinese, use Up/Down and Return, or clear the selection. Unavailable options cannot be chosen.") {
            Combobox(selection: $city, options: [
                SelectOption(value: "beijing", label: "北京 · Beijing"),
                SelectOption(value: "shanghai", label: "上海 · Shanghai · International collaboration workspace 👩🏽‍💻"),
                SelectOption(value: "hongkong", label: "香港 · Hong Kong"), SelectOption(value: "london", label: "London"),
                SelectOption(value: "unavailable", label: "Unavailable", isEnabled: false)
            ]) { $0.isEnabled = options.isEnabled; $0.placeholder = "Choose a city" }.frame(maxWidth: 360)
            Text("Selected: \(city ?? "None")").font(.caption).foregroundColor(.onSurfaceMuted)
        }
    }
}

struct NotificationStory: View {
    @State private var controller = ToastController(maxVisible: 3)
    @State private var count = 0
    @State private var position: ToastPosition = .automatic
    var body: some View {
        StorySection("Toast queue", "Notifications appear at the window edge. Hover pauses expiry. Add several to see the bounded queue, replace the same stable ID, or use an inline action. Automatic positions the banner at the top trailing edge at every width.") {
            Box(direction: .row, alignItems: .center, wrap: .wrap, spacing: 10) {
                Button("Notify") {
                    count += 1
                    controller.post(ToastNotification("Project saved · \(count)") { $0.tone = .success; $0.message = "Your changes are available." })
                }.debugName("toast-notify")
                Button("Toast with undo") {
                    count += 1
                    let saved = count
                    controller.post(ToastNotification("Project saved · \(saved)", id: "saved-\(saved)") {
                        $0.tone = .success
                        $0.duration = nil
                        $0.message = "Your changes are available."
                        $0.actions = [
                            ToastAction("Undo", id: "undo") { count = max(0, saved - 1) },
                            ToastAction("Retry", id: "retry") {
                                controller.post(ToastNotification("Retrying save", id: "retry") { $0.duration = 2 })
                            },
                        ]
                    })
                }.buttonStyle(.secondary).debugName("toast-with-undo")
                Button("Replace status") {
                    count += 1
                    controller.post(ToastNotification("Import status · \(count)", id: "import") { $0.message = "This status replaces the previous import notification." })
                }.buttonStyle(.secondary)
                Button("Persistent warning") { controller.post(ToastNotification("Action required", id: "warning") { $0.duration = nil; $0.tone = .warning; $0.message = "Dismiss this notification when you have read it." }) }.buttonStyle(.warning)
                Button("Clear") { controller.clear() }.buttonStyle(.ghost).debugName("toast-clear")
            }
            Row(alignment: .center, spacing: 10) {
                Text("Position").font(.caption).foregroundColor(.onSurfaceMuted)
                Select(selection: $position, options: [
                    SelectOption(value: .automatic, label: "Automatic"),
                    SelectOption(value: .topTrailing, label: "Top trailing"),
                    SelectOption(value: .bottomTrailing, label: "Bottom trailing"),
                ], width: 180)
            }
            Text("Visible: \(controller.notifications.count) · Queued: \(controller.queuedCount)").font(.caption).foregroundColor(.onSurfaceMuted)
            NotificationHost(controller, position: position)
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
