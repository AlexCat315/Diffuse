import EditorCore
import EngineKernel
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

    private static let warningIcon = BundleImageResource.svg(
        named: "warning", in: .module, subdirectory: "PanelIcons")

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

                        Text(L("The scene has unsaved changes. Save before closing?"))
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
                    Button(L("Close Without Saving"), role: .destructive) {
                        proceed()
                    }
                    .buttonStyle(.secondary)

                    Spacer(minLength: 0)

                    Button(L("Cancel")) {
                        cancel()
                    }
                    .buttonStyle(.ghost)

                    Button(L("Save and Close")) {
                        saveAndClose()
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
            saveAndClose()
        default:
            break
        }
        return true
    }

    private func cancel() {
        app.store.dispatch(.dismissCloseRequest)
    }

    private func saveAndClose() {
        _ = app.saveSceneManifest()
        proceed()
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
