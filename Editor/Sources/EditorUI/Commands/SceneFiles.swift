internal import EditorCore
private import Foundation
internal import CoveUI

enum EditorSceneFileCoordinator {
    static func requestOpen(app: EditorApplication) {
        guard EditorSceneAuthoringPolicy.canEditScene(
            during: app.store.state.timing.playbackState
        ) else {
            app.logConsole("Stop simulation before opening another scene", severity: .warning)
            return
        }
        guard let display = AppDisplayHandleHolder.current else {
            app.logConsole("Scene picker is unavailable", severity: .error, detail: "No active display")
            return
        }
        let defaultPath = URL(fileURLWithPath: app.projectDirectory, isDirectory: true)
            .appendingPathComponent(".cove", isDirectory: true).path
        MainActor.assumeIsolated {
            display.requestOpenFile(filters: [(name: L("Cove Scene"), extensions: ["json"])],
                                    allowsMultiple: false,
                                    defaultPath: defaultPath) { paths in
                guard let path = paths.first else { return }
                app.requestOpenSceneManifest(at: URL(fileURLWithPath: path))
            }
        }
    }
}
