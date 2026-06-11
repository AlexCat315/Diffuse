import EditorCore
import GuavaUIApp
import GuavaUICompose
import GuavaUIRuntime

/// Modal raised when the OS asks to close a dirty window (the platform close
/// was vetoed by the interceptor). Resolves by saving, discarding, or
/// cancelling; the close is then re-issued programmatically, which bypasses
/// the interceptor.
struct UnsavedChangesDialog: View {
    let app: EditorApplication
    let request: EditorPendingCloseRequest

    var body: some View {
        Column(alignment: .center, spacing: 0) {
            Column(alignment: .leading, spacing: 0) {
                Text(L("Unsaved Changes"))
                    .font(.bodyStrong)
                    .foregroundColor(.onSurface)
                    .padding(horizontal: 16, vertical: 12)

                Divider()

                Text(L("The scene has unsaved changes. Save before closing?"))
                    .font(.body)
                    .foregroundColor(.onSurfaceVariant)
                    .padding(horizontal: 16, vertical: 14)

                Divider()

                Row(alignment: .center, spacing: 8) {
                    Button(L("Cancel")) {
                        app.store.dispatch(.dismissCloseRequest)
                    }
                    .buttonStyle(.secondary)

                    Spacer(minLength: 0)

                    Button(L("Close Without Saving"), role: .destructive) {
                        proceed()
                    }
                    .buttonStyle(.secondary)

                    Button(L("Save and Close")) {
                        _ = app.saveSceneManifest()
                        proceed()
                    }
                }
                .padding(horizontal: 16, vertical: 12)
            }
            .frame(width: 420)
            .background(.surfaceFloating)
            .cornerRadius(12)
            .border(.border, width: 1)
            .padding(horizontal: 0, vertical: 120)
        }
        .background(.overlay)
    }

    private func proceed() {
        app.store.dispatch(.dismissCloseRequest)
        let windowID = request.windowID
        MainActor.assumeIsolated {
            guard let display = AppDisplayHandleHolder.current else { return }
            if let windowID {
                display.closeWindow(windowID)
            } else {
                display.quit()
            }
        }
    }
}
