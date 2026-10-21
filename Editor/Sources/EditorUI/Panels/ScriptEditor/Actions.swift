internal import EditorCore
internal import Foundation
internal import GuavaUI
#if canImport(AppKit)
private import AppKit
#endif

/// File-level script actions shared by the Swift tab's menu and the Files tree.
enum ScriptFileActions {
    /// Build, trust and file actions for the script at `path`.
    static func entries(app: EditorApplication, path: String) -> [MenuEntry] {
        let scripts = app.workstation.scripts
        let trusted = scripts.snapshot.trustState.allowsExecution
        let url = URL(fileURLWithPath: app.projectDirectory).appendingPathComponent(path)
        return [
            .item(MenuItem(id: "script-build", title: L("Build & Reload"), isEnabled: trusted,
                           action: scripts.compileSelected)),
            .item(MenuItem(id: "script-new", title: L("New Script")) { newScript(app: app) }),
            .separator("script-file"),
            .item(MenuItem(id: "script-external", title: L("Open External")) { openExternally(url) }),
            .item(MenuItem(id: "script-reveal", title: L("Reveal")) { reveal(url) }),
            .separator("script-trust"),
            .item(MenuItem(id: "script-trust", title: trusted ? L("Revoke Project Trust") : L("Trust Project")) {
                scripts.setProjectTrusted(!trusted)
            }),
            .separator("script-delete"),
            .item(MenuItem(id: "script-delete", title: L("Delete Script"), role: .destructive) {
                confirmDelete(app: app, path: path)
            }),
        ]
    }

    static func newScript(app: EditorApplication) {
        app.workstation.createScript(source: ScriptTemplate.default)
    }

    /// Deleting removes the file from disk, so it always asks first.
    static func confirmDelete(app: EditorApplication, path: String) {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        Task { @MainActor in
            #if canImport(AppKit)
            let alert = NSAlert()
            alert.messageText = String(format: L("Delete %@?"), name)
            alert.informativeText = L("This permanently removes the script from the project.")
            alert.alertStyle = .warning
            alert.addButton(withTitle: L("Delete"))
            alert.addButton(withTitle: L("Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            #endif
            app.workstation.deleteScript(atDocument: path)
        }
    }

    private static func openExternally(_ url: URL) {
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }

    private static func reveal(_ url: URL) {
        #if canImport(AppKit)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        #endif
    }
}
