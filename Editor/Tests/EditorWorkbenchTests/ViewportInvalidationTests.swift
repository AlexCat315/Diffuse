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
        let displayRequests = DisplayRequestCounter()
        app.setDisplayInvalidationHandler { displayRequests.increment() }
        let initialRequests = displayRequests.value
        let sceneRevision = app.scene.revision
        app.setViewportGridEnabled(false)
        #expect(!app.store.state.viewport.gridEnabled)
        #expect(displayRequests.value == initialRequests + 1)
        app.setViewportGridEnabled(false)
        #expect(displayRequests.value == initialRequests + 1)
        app.setViewportGridEnabled(true)
        #expect(app.store.state.viewport.gridEnabled)
        #expect(displayRequests.value == initialRequests + 2)
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
        let displayRequests = DisplayRequestCounter()
        app.setDisplayInvalidationHandler { displayRequests.increment() }
        let initialRequests = displayRequests.value
        app.setViewportDrawableSize(.init(width: 640, height: 360))
        #expect(displayRequests.value == initialRequests + 1)
        app.setViewportDrawableSize(.init(width: 640, height: 360))
        #expect(displayRequests.value == initialRequests + 1)
        app.setViewportDrawableSize(.init(width: 800, height: 450))
        #expect(displayRequests.value == initialRequests + 2)
    }
}

private final class DisplayRequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
