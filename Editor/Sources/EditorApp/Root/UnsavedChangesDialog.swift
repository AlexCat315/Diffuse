import EditorCore
import EngineKernel
import GuavaUIApp
import GuavaUICompose
import GuavaUIRuntime

/// Resolves a destructive document action by saving, discarding, or cancelling.
struct UnsavedChangesDialog: View {
    let app: EditorApplication
    let request: EditorPendingCloseRequest

    private static let warningIcon = BundleImageResource.svg(
        named: "warning",
        in: EditorAppResourceBundle.bundle,
        subdirectory: "PanelIcons"
    )

    var body: some View {
        ModalBarrier {
            ShortcutHost(onKeyDown: handleKey)

            Column(alignment: .leading, spacing: 0) {
                Row(alignment: .top, spacing: 12) {
                    Box(direction: .row, alignItems: .center, justifyContent: .center) {
                        Icon(Self.warningIcon, size: 20, color: .warning)
                    }
                    .frame(width: 36, height: 36)
                    .background(.warning.opacity(0.14))
                    .cornerRadius(10)

                    Column(alignment: .leading, spacing: 5) {
                        Text(L("Unsaved Changes"))
                            .font(.headline)
                            .foregroundColor(.onSurface)

                        Text(message)
                            .font(.body)
                            .foregroundColor(.onSurfaceVariant)
                            .lineHeight(20)
                    }
                    .flex(1, shrink: 1)
                }
                .padding(EdgeInsets(top: 20, leading: 20, bottom: 18, trailing: 20))

                // macOS sheet convention: destructive option parked on the
                // leading edge, cancel + default action trailing.
                Row(alignment: .center, spacing: 8) {
                    Button(discardTitle, role: .destructive) {
                        discardAndProceed()
                    }
                    .buttonStyle(.secondary)

                    Spacer(minLength: 0)

                    Button(L("Cancel")) {
                        cancel()
                    }
                    .buttonStyle(.ghost)

                    Button(saveTitle) {
                        saveAndProceed()
                    }
                    .buttonStyle(.primary)
                }
                .padding(EdgeInsets(top: 0, leading: 20, bottom: 16, trailing: 20))
            }
            .frame(width: 440)
            .background(.surfaceFloating)
            .cornerRadius(14)
            .border(.border, width: 1)
        }
    }

    /// Escape cancels, Return saves; everything else is swallowed so the
    /// editor's app-level shortcuts stay inert behind the modal.
    private func handleKey(_ key: KeyEvent) -> Bool {
        guard !key.isRepeat else { return true }
        switch key.scancode {
        case Scancode.escape:
            cancel()
        case Scancode.return, Scancode.keypadEnter:
            saveAndProceed()
        default:
            break
        }
        return true
    }

    private func cancel() {
        app.store.dispatch(.dismissCloseRequest)
    }

    private var message: String {
        switch request.action {
        case .close:
            return L("The scene has unsaved changes. Save before closing?")
        case .newScene:
            return L("The scene has unsaved changes. Save before creating a new scene?")
        case .openScene:
            return L("The scene has unsaved changes. Save before opening another scene?")
        }
    }

    private var discardTitle: String {
        switch request.action {
        case .close: return L("Close Without Saving")
        case .newScene: return L("Discard and Create New")
        case .openScene: return L("Discard and Open")
        }
    }

    private var saveTitle: String {
        switch request.action {
        case .close: return L("Save and Close")
        case .newScene: return L("Save and Create New")
        case .openScene: return L("Save and Open")
        }
    }

    private func saveAndProceed() {
        guard app.saveSceneManifest() != nil else { return }
        proceed()
    }

    private func discardAndProceed() {
        // Keep the recovery snapshot until the selected scene has actually
        // loaded. If the file is corrupt or incompatible, the user's current
        // unsaved work must remain recoverable.
        if request.action == .openScene {
            app.store.dispatch(.dismissCloseRequest)
            _ = openRequestedScene()
            return
        }
        app.discardAutosavedScene()
        proceed()
    }

    private func proceed() {
        app.store.dispatch(.dismissCloseRequest)
        switch request.action {
        case .newScene:
            app.resetPreviewScene()
        case .openScene:
            _ = openRequestedScene()
        case .close:
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

    private func openRequestedScene() -> EditorSceneManifest? {
        if let path = request.documentPath {
            return app.openSceneManifest(at: URL(fileURLWithPath: path))
        }
        return app.openSceneManifest()
    }
}
