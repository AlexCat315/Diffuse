@testable import EditorCore
import Foundation
import Testing

@Suite("Editor asset reload")
struct EditorAssetReloadTests {
    @Test("asset reload invalidates subscribed editor UI")
    func reloadInvalidatesUI() throws {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("guava-asset-reload-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: project) }
        try FileManager.default.createDirectory(at: project,
                                                withIntermediateDirectories: true)
        let application = try EditorApplication(projectDirectory: project.path)
        defer { application.shutdown() }
        let before = application.store.presentationRevision

        #expect(application.reloadAssets() == 0)
        #expect(application.store.presentationRevision > before)
    }
}
