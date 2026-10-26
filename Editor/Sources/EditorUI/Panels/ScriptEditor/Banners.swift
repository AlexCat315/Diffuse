internal import EditorCore
internal import CoveUI
internal import CoveUIRuntime

/// Scripts are native code with the Editor's permissions, so an untrusted
/// project says why it will not build and offers the one way forward.
struct ScriptTrustBanner: View {
    let app: EditorApplication
    let snapshot: ScriptWorkspaceSnapshot

    var body: some View {
        AnimatedVisibility(isVisible: !snapshot.trustState.allowsExecution) {
            Row(alignment: .center, spacing: 10) {
                Icon(UIIcons.Status.shield, size: 14, color: .warning)
                Column(alignment: .leading, spacing: 2) {
                    Text(L("Swift script execution is restricted")).font(.bodyStrong).foregroundColor(.warning)
                    Text(L("Scripts are native code with the Editor's permissions. Trust only projects you know."), lineLimit: 2)
                        .font(.caption).foregroundColor(.onSurfaceVariant)
                }.flex(1, shrink: 1).frame(minWidth: 0)
                Button(L("Trust Project")) { app.workstation.scripts.setProjectTrusted(true) }
                    .buttonStyle(.primary).debugName("script-trust")
            }
            .padding(horizontal: 12, vertical: 8)
            .background(.warning.opacity(0.10))
            .debugName("script-trust-banner")
        }
        AnimatedVisibility(isVisible: snapshot.trustState.allowsExecution && snapshot.trustWarning != nil) {
            Text(snapshot.trustWarning ?? "", lineLimit: 2).font(.caption).foregroundColor(.warning)
                .padding(horizontal: 12, vertical: 6)
                .frame(width: .percent(100), minWidth: 0)
                .background(.warning.opacity(0.08))
        }
    }
}

/// The file changed on disk while the editor holds its own version.
struct ScriptExternalChangeBanner: View {
    let app: EditorApplication
    let document: ScriptWorkspaceDocument

    var body: some View {
        AnimatedVisibility(isVisible: document.externalChange != .none) {
            if document.externalChange == .deletedOnDisk {
                row(L("This file was deleted outside the Editor."),
                    disk: L("Close File"), editor: L("Recreate File"))
            } else {
                row(L("This file changed on disk while you have unsaved edits."),
                    disk: L("Reload from Disk"), editor: L("Keep Editor Version"))
            }
        }
    }

    private func row(_ message: String, disk: String, editor: String) -> some View {
        let scripts = app.workstation.scripts
        return Row(alignment: .center, spacing: 8) {
            Icon(UIIcons.Status.alertTriangle, size: 12, color: .warning)
            Text(message, lineLimit: 1).font(.caption).foregroundColor(.onSurfaceVariant).flex(1, shrink: 1).frame(minWidth: 0)
            Button(disk) { scripts.resolveSelectedExternalChange(useDiskVersion: true) }.buttonStyle(.secondary)
            Button(editor) { scripts.resolveSelectedExternalChange(useDiskVersion: false) }.buttonStyle(.primary)
        }
        .padding(horizontal: 12, vertical: 6)
        .background(.warning.opacity(0.10))
        .debugName("script-external-change")
    }
}
