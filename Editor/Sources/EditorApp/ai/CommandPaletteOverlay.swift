import EditorCore
import GuavaKit

struct CommandPaletteOverlay: GuavaKit.View {
    let app: EditorApplication
    @Observed var store: EditorStore
    @State var inputText: String = ""

    init(app: EditorApplication) {
        self.app = app
        self.store = app.store
    }

    var body: some GuavaKit.View {
        // Full-screen backdrop
        Column(alignment: .center, spacing: 0) {

            // Palette card
            Column(alignment: .stretch, spacing: 0) {
                // Header row
                Row(alignment: .center, spacing: 8) {
                    Text(L("AI Command"))
                        .font(.bodyStrong)
                        .foregroundColor(.onSurface)
                        .flex(1, shrink: 1)

                    Button(action: { dismiss() }) {
                        Text("✕")
                            .font(.caption)
                            .foregroundColor(.onSurfaceMuted)
                    }
                }
                .padding(horizontal: 14, vertical: 10)

                Divider()

                // Text input
                TextField(
                    text: inputText,
                    placeholder: L("Describe what you want to do…"),
                    onChange: { inputText = $0 },
                    onSubmit: { submitAndClose() }
                )
                .padding(horizontal: 14, vertical: 10)

                Divider()

                // Hint row
                Row(alignment: .center, spacing: 6) {
                    Text(L("Enter to submit · Escape to close"))
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)
                        .flex(1, shrink: 1)
                }
                .padding(horizontal: 14, vertical: 8)
            }
            .frame(width: 480)
            .background(.surface)
            .cornerRadius(6)
            .padding(horizontal: 0, vertical: 80)
        }
        .background(.overlay)
    }

    private func submitAndClose() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        app.submitNaturalLanguageIntent(trimmed)
        dismiss()
    }

    private func dismiss() {
        app.store.dispatch(.setCommandPaletteVisible(false))
        inputText = ""
    }
}
