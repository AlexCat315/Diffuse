import EditorCore
import Foundation
import Testing

@Suite("Viewport presentation invalidation", .serialized)
struct ViewportInvalidationTests {
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
