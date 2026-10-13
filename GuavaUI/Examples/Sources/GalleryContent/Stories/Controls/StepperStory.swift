import GuavaUI
import GuavaUIRuntime

struct StepperStory: View {
    let options: GalleryOptions
    @State private var selected: String? = "details"
    @State private var status: StepStatus = .pending
    @State private var unlockReview = false
    private var steps: [StepperItem<String>] {
        [StepperItem("account", "Account") { $0.status = .completed; $0.detail = "Profile saved" },
         StepperItem("details", "Details") { $0.status = status; $0.detail = "Configure your workspace" },
         StepperItem("review", "Review") { $0.isEnabled = unlockReview; $0.detail = unlockReview ? "Ready to review" : "Complete details first" }]
    }
    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 24) {
            StorySection("A controlled workflow", "Click a step or use Left/Right and Home/End. Review stays unavailable until details succeed. Going back preserves the saved outcomes.") {
                Stepper(steps, selection: $selected) { $0.isEnabled = options.isEnabled }
                Row(alignment: .center, spacing: 10) {
                    Button("Start", isEnabled: options.isEnabled) { status = .inProgress; unlockReview = false }
                    Button("Fail", isEnabled: options.isEnabled) { status = .failed; unlockReview = false }.buttonStyle(.destructive)
                    Button("Complete", isEnabled: options.isEnabled) { status = .completed; unlockReview = true }.buttonStyle(.secondary)
                    Text("Current: \(selected ?? "None")").font(.caption).foregroundColor(.onSurfaceMuted)
                }
                if status == .failed { Alert("Details could not be saved", message: "Retry with Start, or review your configuration.", tone: .danger) }
            }
            StorySection("Vertical steps", "Up/Down follow the vertical axis. The status glyph and text describe the outcome without relying on color.") {
                Stepper(steps, selection: $selected) {
                    $0.axis = .vertical; $0.isEnabled = options.isEnabled; $0.label = "Setup progress"
                }.frame(width: 360)
            }
            StorySection("No steps", "An empty workflow exposes no invalid selection, actions or keyboard stop.") {
                Stepper<String>([], selection: .constant(nil))
            }
        }
    }
}
