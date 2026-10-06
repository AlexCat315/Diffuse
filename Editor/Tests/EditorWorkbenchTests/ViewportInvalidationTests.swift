import EditorCore
import Foundation
import Testing

@Suite("Viewport presentation invalidation", .serialized)
struct ViewportInvalidationTests {
    @Test("grid toggles request a frame without changing the scene")
    func gridToggleRequestsDisplay() throws {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("guava-grid-invalidation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        let app = try EditorApplication(projectDirectory: project.path)
        defer { app.shutdown() }
        var displayRequests = 0
        app.setDisplayInvalidationHandler { displayRequests += 1 }
        let sceneRevision = app.scene.revision
        app.setViewportGridEnabled(false)
        #expect(!app.store.state.viewport.gridEnabled)
        #expect(displayRequests == 1)
        app.setViewportGridEnabled(false)
        #expect(displayRequests == 1)
        app.setViewportGridEnabled(true)
        #expect(app.store.state.viewport.gridEnabled)
        #expect(displayRequests == 2)
        #expect(app.scene.revision == sceneRevision)
    }

    @Test("a new drawable size schedules a frame, identical reports do not")
    func drawableSizeRequestsDisplay() throws {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("guava-viewport-invalidation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        let app = try EditorApplication(projectDirectory: project.path, seedPreviewScene: true)
        defer { app.shutdown() }
        var displayRequests = 0
        app.setDisplayInvalidationHandler { displayRequests += 1 }
        app.setViewportDrawableSize(.init(width: 640, height: 360))
        #expect(displayRequests == 1)
        app.setViewportDrawableSize(.init(width: 640, height: 360))
        #expect(displayRequests == 1)
        app.setViewportDrawableSize(.init(width: 800, height: 450))
        #expect(displayRequests == 2)
    }
}
