// TODO: Full migration blocked by TextField widget (batch 4).
// Structure migrated to GuavaKit.View; TextField and button style calls commented out.
// See original in git history for the GuavaUICompose version.

import EditorCore
import GuavaKit

struct CommandPaletteOverlay: GuavaKit.View {
    let app: EditorApplication
    @Observed var store: EditorStore

    // TODO: Restore when TextField is available
    // @State private var text: String = ""

    init(app: EditorApplication) {
        self.app = app
        self.store = app.store
    }

    var body: some GuavaKit.View {
        let isResolving = store.aiStatusMessage == "Resolving…"

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

                    if isResolving {
                        Text(L("Resolving…"))
                            .font(.caption)
                            .foregroundColor(.onSurfaceMuted)
                    }

                    Button(action: { dismiss() }) {
                        Text("✕")
                            .font(.caption)
                            .foregroundColor(.onSurfaceMuted)
                    }
                }
                .padding(horizontal: 14, vertical: 10)

                Divider()

                // TODO: TextField — batch 4
                Text(L("Describe what you want to do…"))
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
                    .padding(horizontal: 14, vertical: 10)

                Divider()

                // Hint row
                Row(alignment: .center, spacing: 6) {
                    Text(L("Enter to submit · Escape to close · Cmd+K to reopen"))
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)
                        .flex(1, shrink: 1)

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
        .frame(width: nil, height: nil) // will be % when percent support lands
        .background(.overlay)
    }

    private func dismiss() {
        app.store.dispatch(.setCommandPaletteVisible(false))
    }
}
