import EditorCore
import GuavaUICompose
import GuavaUIRuntime

/// ⌘K-style AI command palette: a floating card on the modal scrim.
struct CommandPaletteOverlay: View {
    let app: EditorApplication
    let store: EditorStore
    @State private var inputText: String = ""

    init(app: EditorApplication) {
        self.app = app
        self.store = app.store
    }

    var body: some View {
        ModalBarrier(justifyContent: .flexStart, onBackgroundTap: { dismiss() }) {
            Column(alignment: .leading, spacing: 0) {
                Row(alignment: .center, spacing: 8) {
                    Text(L("AI Command"))
                        .font(.bodyStrong)
                        .foregroundColor(.onSurface)
                        .flex(1, shrink: 1)

                    Button(icon: .resource(UICommonIcons.close),
                           size: 12,
                           action: { dismiss() })
                    .buttonStyle(GhostButtonStyle())
                }
                .padding(horizontal: 14, vertical: 10)

                Divider()

                TextField(L("Describe what you want to do…"),
                          text: $inputText,
                          onSubmit: { submitAndClose() })
                    .padding(horizontal: 14, vertical: 10)

                Divider()

                Row(alignment: .center, spacing: 6) {
                    Text(L("Enter to submit · Escape to close"))
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)
                        .flex(1, shrink: 1)
                }
                .padding(horizontal: 14, vertical: 8)
            }
            .frame(width: 480)
            .background(.surfaceFloating)
            .cornerRadius(12)
            .border(.border, width: 1)
            .shadow(color: Color(r: 0, g: 0, b: 0, a: 0.45), offsetY: 18, blur: 48)
            .padding(EdgeInsets(top: 80, leading: 0, bottom: 0, trailing: 0))
        }
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
