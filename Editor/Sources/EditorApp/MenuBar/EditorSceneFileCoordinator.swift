import EditorCore
import Foundation
import GuavaUIApp

enum EditorSceneFileCoordinator {
    static func requestOpen(app: EditorApplication) {
        guard let display = AppDisplayHandleHolder.current else {
            app.logConsole("Scene picker is unavailable", severity: .error, detail: "No active display")
            return
        }
        let defaultPath = URL(fileURLWithPath: app.projectDirectory, isDirectory: true)
            .appendingPathComponent(".guava", isDirectory: true).path
        MainActor.assumeIsolated {
            display.requestOpenFile(filters: [(name: L("Guava Scene"), extensions: ["json"])],
                                    allowsMultiple: false,
                                    defaultPath: defaultPath) { paths in
                guard let path = paths.first else { return }
                app.requestOpenSceneManifest(at: URL(fileURLWithPath: path))
            }
        }
    }
}
