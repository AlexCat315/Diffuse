import EngineKernel
import Foundation
import SceneRuntime
import ScriptRuntime
import Testing
@testable import EditorCore

private final class PlaybackCallbacks: @unchecked Sendable {
    private let lock = NSLock()
    private var callbacks: [String] = []
    func record(_ value: String) { lock.withLock { callbacks.append(value) } }
    var values: [String] { lock.withLock { callbacks } }
}

@Suite("Editor script playback", .serialized)
@MainActor
struct EditorScriptPlaybackTests {
    @Test("gameplay starts only in Play, Pause freezes callbacks, and each Play gets a new lifecycle")
    func scriptPlaybackLifecycle() throws {
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("guava-script-playback-\(UUID())")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: project) }
        let app = try EditorApplication(projectDirectory: project.path)
        defer { app.shutdown() }
        let callbacks = PlaybackCallbacks()
        let controller = try #require(app.scene.spawnEntity(template: .empty))
        app.scene.scriptRuntime.register(named: "test.playback") {
            Script(onStart: { context in
                callbacks.record("start")
                _ = context.createEntity(named: "Play Object")
            }, onTick: { _ in callbacks.record("update") }, onDestroy: { context in
                callbacks.record(context.localTransform(of: context.entity) != nil ? "destroy" : "invalid-destroy")
            })
        }
        _ = app.scene.scene.setComponent(ScriptComponent(ScriptBinding(identifier: "test.playback")),
                                        for: EntityID(rawValue: controller))
        app.scene.notifyRevisionChanged()
        let savedURL = try #require(app.saveSceneManifest())
        let savedData = try Data(contentsOf: savedURL)
        app.tick(deltaTime: 1.0 / 60)
        #expect(callbacks.values.isEmpty)
        #expect(app.scene.entityCount == 1)
        app.store.dispatch(.setViewportRealtime(true))
        app.tick(deltaTime: 1.0 / 60)
        #expect(callbacks.values.isEmpty)
        let authored = app.scene.manifest()
        app.applyPlaybackState(.playing)
        app.tick(deltaTime: 1.0 / 60)
        #expect(callbacks.values == ["start", "update"])
        #expect(app.scene.entityCount == 2)
        app.applyPlaybackState(.paused)
        app.tick(deltaTime: 1.0 / 60)
        #expect(callbacks.values == ["start", "update"])
        app.applyPlaybackState(.playing)
        app.tick(deltaTime: 1.0 / 60)
        #expect(callbacks.values == ["start", "update", "update"])
        app.applyPlaybackState(.stopped)
        #expect(callbacks.values == ["start", "update", "update", "destroy"])
        #expect(app.scene.manifest() == authored)
        #expect(!app.hasUnsavedSceneChanges)
        app.tick(deltaTime: 1.0 / 60)
        app.applyPlaybackState(.playing)
        app.tick(deltaTime: 1.0 / 60)
        #expect(callbacks.values.suffix(2) == ["start", "update"])
        #expect(callbacks.values.filter { $0 == "start" }.count == 2)
        #expect(app.scene.entityCount == 2)
        app.applyPlaybackState(.stopped)
        #expect(callbacks.values.filter { $0 == "destroy" }.count == 2)
        #expect(try Data(contentsOf: savedURL) == savedData)
    }
}
