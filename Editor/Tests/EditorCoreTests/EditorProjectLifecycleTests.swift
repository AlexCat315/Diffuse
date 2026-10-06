import Foundation
import SceneRuntime
import GuavaUIRuntime
import GuavaUICompose
import Testing
@testable import EditorCore

@Suite("Project lifecycle", .serialized)
@MainActor
struct EditorProjectLifecycleTests {
    private func parent() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("guava-project-lifecycle-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }

    @Test("blank projects open empty and never create default scripts")
    func blankProject() throws {
        let parent = try parent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let created = try EditorProjectLifecycle.create(name: " My Game ", parent: parent)
        #expect(created.directory.lastPathComponent == "My Game")
        #expect(try EditorProjectLifecycle.inspect(created.directory).descriptor == created.descriptor)
        #expect(try FileManager.default.contentsOfDirectory(atPath: created.directory.appendingPathComponent("Scripts").path).isEmpty)
        #expect(FileManager.default.fileExists(atPath: created.directory.appendingPathComponent("Assets").path))
        let app = try EditorApplication(projectDirectory: created.directory.path)
        defer { app.shutdown() }
        #expect(app.scene.entityCount == 0)
        #expect(app.scene.defaultSelectionID == nil)
        #expect(app.restoreProjectSceneAtLaunch()?.entityCount == 0)
        #expect(app.scriptWorkspace.snapshot.documents.isEmpty)
        #expect(!app.hasUnsavedSceneChanges)
        let cube = try #require(app.scene.spawnEntity(template: .cube))
        app.store.dispatch(.setSelectedEntity(cube))
        #expect(app.saveSceneManifest() != nil)
        app.requestNewScene()
        #expect(app.store.state.document.pendingCloseRequest == nil)
        #expect(app.scene.entityCount == 0)
        #expect(app.store.state.selection.selectedEntityID == nil)
        #expect(app.hasUnsavedSceneChanges)
        #expect(app.saveSceneManifest() != nil)
        #expect(!app.hasUnsavedSceneChanges)
    }

    @Test("creation rejects collisions and traversal without touching existing contents")
    func creationBoundaries() throws {
        let parent = try parent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let existing = parent.appendingPathComponent("Existing")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        let sentinel = existing.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sentinel)
        #expect(throws: (any Error).self) { try EditorProjectLifecycle.create(name: "Existing", parent: parent) }
        for name in ["", ".", "..", "../Escape", "A/B", "A\\B", ".hidden", "bad:", "bad\nname"] {
            #expect(throws: (any Error).self) { try EditorProjectLifecycle.create(name: name, parent: parent) }
        }
        #expect(try Data(contentsOf: sentinel) == Data("keep".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path) == ["Existing"])
    }

    @Test("opening validates first and supports legacy empty project folders")
    func validation() throws {
        let parent = try parent()
        defer { try? FileManager.default.removeItem(at: parent) }
        #expect(throws: (any Error).self) { try EditorProjectLifecycle.inspect(parent) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
        try FileManager.default.createDirectory(at: parent.appendingPathComponent(".guava"), withIntermediateDirectories: false)
        #expect(try EditorProjectLifecycle.inspect(parent).descriptor == nil)
        let scene = parent.appendingPathComponent(EditorProjectLifecycle.scenePath)
        try Data("corrupt".utf8).write(to: scene)
        #expect(throws: (any Error).self) { try EditorProjectLifecycle.inspect(parent) }
        #expect(try Data(contentsOf: scene) == Data("corrupt".utf8))
        try FileManager.default.removeItem(at: parent.appendingPathComponent(".guava"))
        let outside = try self.parent()
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: parent.appendingPathComponent(".guava"), withDestinationURL: outside)
        #expect(throws: (any Error).self) { try EditorProjectLifecycle.inspect(parent) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test("the bundled example is a writable independent copy with matching script identity")
    func example() throws {
        let parent = try parent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let first = try EditorProjectLifecycle.create(name: "First", parent: parent, template: .crystalRush)
        let second = try EditorProjectLifecycle.create(name: "Second", parent: parent, template: .crystalRush)
        #expect(first.descriptor?.id != second.descriptor?.id)
        let source = first.directory.appendingPathComponent("Scripts/CrystalRush.swift")
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        #expect(try Data(contentsOf: source) == Data(contentsOf: repo.appendingPathComponent("examples/CrystalRush/Scripts/CrystalRush.swift")))
        let scene = try JSONDecoder().decode(EditorSceneManifest.self, from: Data(contentsOf: first.directory.appendingPathComponent(EditorProjectLifecycle.scenePath)))
        #expect(scene.entityCount == 1)
        #expect(scene.roots.first?.name == "Game Controller")
        let app = try EditorApplication(projectDirectory: first.directory.path)
        defer { app.shutdown() }
        #expect(app.restoreProjectSceneAtLaunch()?.entityCount == 1)
        let document = try #require(app.scriptWorkspace.snapshot.documents.first)
        #expect(document.file.identifier == scene.roots.first?.script?.bindings.first?.identifier)
        #expect(!app.dynamicScriptManager.projectTrustState.allowsExecution)
        try Data("modified".utf8).write(to: source)
        #expect(try Data(contentsOf: second.directory.appendingPathComponent("Scripts/CrystalRush.swift")) != Data("modified".utf8))
    }

    @Test("deletion is recoverable and legacy folders are never deleted")
    func recoverableDeletion() throws {
        let parent = try parent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let created = try EditorProjectLifecycle.create(name: "Trash Test", parent: parent)
        let corruptScene = Data("corrupt but recoverable".utf8)
        try corruptScene.write(to: created.directory.appendingPathComponent(EditorProjectLifecycle.scenePath))
        let trashURL = try EditorProjectLifecycle.moveToTrash(created.directory)
        #expect(!FileManager.default.fileExists(atPath: created.directory.path))
        #expect(try EditorProjectLifecycle.inspect(trashURL, validateScene: false).descriptor == created.descriptor)
        // Restore our test artifact so cleanup leaves no extra project in the user's Trash.
        try FileManager.default.moveItem(at: trashURL, to: created.directory)
        #expect(try EditorProjectLifecycle.inspect(created.directory, validateScene: false).descriptor == created.descriptor)
        #expect(try Data(contentsOf: created.directory.appendingPathComponent(EditorProjectLifecycle.scenePath)) == corruptScene)
        try FileManager.default.createDirectory(at: parent.appendingPathComponent(".guava"), withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try EditorProjectLifecycle.moveToTrash(parent) }
        #expect(FileManager.default.fileExists(atPath: created.directory.path))
    }

    @Test("closing protects unsaved script buffers and saving writes every buffer")
    func closeProject() throws {
        let parent = try parent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let project = try EditorProjectLifecycle.create(name: "Close Test", parent: parent)
        let app = try EditorApplication(projectDirectory: project.directory.path)
        defer { app.shutdown() }
        var closed = false
        app.setCloseProjectHandler { closed = true }
        #expect(app.scriptWorkspace.createScript(name: "One", source: "one"))
        app.scriptWorkspace.updateSelectedSource("unsaved")
        app.requestCloseProject()
        #expect(!closed)
        #expect(app.store.state.document.pendingCloseRequest?.action == .closeProject)
        #expect(app.scriptWorkspace.persistAll())
        #expect(try String(contentsOf: project.directory.appendingPathComponent("Scripts/One.swift"), encoding: .utf8) == "unsaved")
        app.store.dispatch(.dismissCloseRequest)
        app.requestCloseProject()
        #expect(closed)
    }

    @Test("empty scenes can navigate and frame objects without adding camera entities or dirtying the scene")
    func emptyViewportNavigation() throws {
        let scene = EditorSceneAdapter(seedPreviewScene: false)
        scene.tickScene()
        let originalRevision = scene.revision
        let original = scene.currentRenderCamera()
        var refreshes = 0
        scene.onViewportCameraChanged = { refreshes += 1 }
        let frame = ViewportScreenFrame(x: 0, y: 0, width: 800, height: 600)
        scene.orbitCamera(deltaScreenX: 30, deltaScreenY: 10, in: frame)
        scene.panCamera(deltaScreenX: 20, deltaScreenY: 10, in: frame)
        scene.zoomCamera(factor: 0.8)
        scene.freelookCamera(deltaScreenX: 5, deltaScreenY: 5, pressedScancodes: [26], modifiers: [])
        #expect(scene.currentRenderCamera() != original)
        #expect(scene.currentRenderScene().camera == scene.currentRenderCamera())
        #expect(scene.entityCount == 0)
        #expect(scene.revision == originalRevision)
        #expect(refreshes == 4)
        let cube = try #require(scene.spawnEntity(template: .cube))
        scene.setEntityLocalTranslation(cube, to: SIMD3<Float>(12, 4, 2))
        scene.tickScene()
        scene.frameEntity(cube)
        #expect(scene.currentRenderCamera().target == SIMD3<Float>(12, 4, 2))
        #expect(scene.manifest().entityCount == 1)
        #expect(scene.manifest().roots.first?.camera == nil)
    }

}
