import EditorCore
import GuavaUICompose
import GuavaUIRuntime

/// Floating AI command palette, opened via Cmd+K and dismissed via Escape or backdrop click.
///
/// Runs the full three-layer intent cascade (local classifier → AI backend → keyword fallback)
/// and closes itself as soon as the intent is submitted for resolution.
struct CommandPaletteOverlay: View {
    let app: EditorApplication

    @State private var text: String = ""
    @State private var suggestions: [(verbID: String, summary: String, confidence: Double)] = []

    init(app: EditorApplication) {
        self.app = app
    }

    var body: some View {
        StoreScope(app.store) { store in
            let isResolving = store.aiStatusMessage == "Resolving…"

            // Full-screen backdrop — click to dismiss
            Button(action: dismiss) {
                Box(direction: .column,
                    alignItems: .center,
                    justifyContent: .flexStart,
                    spacing: 0) {

                    // Palette card
                    Box(direction: .column, alignItems: .stretch, spacing: 0) {
                        // Header row
                        Row(alignment: .center, spacing: 8) {
                            Text(L("AI Command"))
                                .font(.bodyStrong)
                                .foregroundColor(.onSurface)
                                .flex()

                            if isResolving {
                                Text(L("Resolving…"))
                                    .font(.caption)
                                    .foregroundColor(.onSurfaceMuted)
                            }

                            Button(action: dismiss) {
                                Text("✕")
                                    .font(.caption)
                                    .foregroundColor(.onSurfaceMuted)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(horizontal: 14, vertical: 10)

                        Divider()

                        // Input
                        TextField(
                            L("Describe what you want to do…"),
                            text: $text,
                            clearable: true,
                            onSubmit: { submitAndClose() },
                            onChange: { updateSuggestions($0) },
                            onClear: { text = ""; suggestions = [] }
                        )
                        .padding(horizontal: 14, vertical: 10)

                        // Live suggestions
                        if !suggestions.isEmpty && !isResolving {
                            Divider()
                            suggestionList
                        }

                        Divider()

                        // Hint row
                        Row(alignment: .center, spacing: 6) {
                            Text(L("Enter to submit · Escape to close · Cmd+K to reopen"))
                                .font(.caption)
                                .foregroundColor(.onSurfaceMuted)
                                .flex()

                            let providerLabel = store.aiSettings.provider == .none
                                ? L("keyword only")
                                : store.aiSettings.provider.displayName
                            Text(providerLabel)
                                .font(.caption)
                                .foregroundColor(.onSurfaceMuted)
                                .padding(horizontal: 6, vertical: 2)
                                .background(.surfaceSunken)
                                .cornerRadius(2)
                        }
                        .padding(horizontal: 14, vertical: 8)
                    }
                    .frame(width: 480)
                    .background(.surface)
                    .cornerRadius(6)
                    .padding(horizontal: 0, vertical: 80)
                }
                .frame(width: .percent(100), height: .percent(100))
                .background(.overlay)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var suggestionList: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            for match in suggestions {
                SuggestionRow(summary: match.summary,
                              shortVerb: verbLabel(match.verbID),
                              onSelect: { text = match.summary; submitAndClose() })
            }
        }
    }

    private func updateSuggestions(_ newText: String) {
        suggestions = app.localIntentSuggestions(for: newText, maxCount: 3)
    }

    private func submitAndClose() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        app.submitNaturalLanguageIntent(trimmed)
        dismiss()
    }

    private func dismiss() {
        app.store.dispatch(.setCommandPaletteVisible(false))
        text = ""
        suggestions = []
    }

    private func verbLabel(_ verbID: String) -> String {
        verbID.components(separatedBy: ".").last ?? verbID
    }
}

// MARK: - Suggestion row

private struct SuggestionRow: View {
    let summary: String
    let shortVerb: String
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            Row(alignment: .center, spacing: 8) {
                Text(summary)
                    .font(.body)
                    .foregroundColor(.onSurface)
                    .flex()
                Text(shortVerb)
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
            }
            .padding(horizontal: 14, vertical: 7)
        }
        .buttonStyle(.plain)
    }
}
