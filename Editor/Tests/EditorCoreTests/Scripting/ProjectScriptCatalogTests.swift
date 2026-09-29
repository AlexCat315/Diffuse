@testable import EditorCore
import Foundation
import SceneRuntime
import ScriptRuntime
import Testing

@Suite("Project script catalog")
struct ProjectScriptCatalogTests {
    @Test("missing project catalog still exposes runnable built-in scripts")
    func builtInsWithoutManifest() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let catalog = try ProjectScriptCatalog.load(projectDirectory: root.path)

        #expect(catalog.sourceURL == nil)
        #expect(catalog.entries.count == ScriptPresetKind.allCases.count)
        #expect(catalog.entries.contains { $0.identifier == "guava.rotator" })
    }

    @Test("valid aliases load while invalid entries produce actionable diagnostics")
    func partialCatalogValidation() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeCatalog(
            #"{"schemaVersion":1,"scripts":[{"id":"project.spin","displayName":"Spin","preset":"rotator","defaultParameters":{"speed":[0,3,0]}},{"id":"bad id","preset":"mover"},{"id":"project.unknown","preset":"not-real"},{"id":"project.spin","preset":"mover"}]}"#,
            to: root
        )

        let catalog = try ProjectScriptCatalog.load(projectDirectory: root.path)

        let custom = try #require(catalog.entries.first { $0.identifier == "project.spin" })
        #expect(custom.displayName == "Spin")
        #expect(custom.defaultParametersJSON.contains("\"speed\""))
        #expect(catalog.diagnostics.count == 3)
        #expect(catalog.diagnostics.allSatisfy { $0.severity == .error })
    }

    @Test("monitor notices same-size content replacements and suppresses unchanged polls")
    func monitorContentSignature() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let monitor = ProjectScriptCatalogMonitor(projectDirectory: root.path)
        try writeCatalog(
            #"{"schemaVersion":1,"scripts":[{"id":"project.one","preset":"mover"}]}"#,
            to: root
        )

        #expect(try monitor.loadIfChanged() != nil)
        #expect(try monitor.loadIfChanged() == nil)
        try writeCatalog(
            #"{"schemaVersion":1,"scripts":[{"id":"project.two","preset":"mover"}]}"#,
            to: root
        )
        let reloaded = try #require(try monitor.loadIfChanged())
        #expect(reloaded.entries.contains { $0.identifier == "project.two" })
    }

    @Test("adapter runs named bindings and reports missing identifiers")
    func adapterCatalogApplication() throws {
        let adapter = EditorSceneAdapter()
        _ = adapter.applyProjectScriptCatalog(.builtIn)
        let entity = try #require(adapter.scene.roots().first)
        _ = adapter.scene.setComponent(
            ScriptComponent(bindings: [
                ScriptBinding(identifier: "guava.rotator",
                              parametersJSON: #"{"speed":[0,1,0]}"#),
                ScriptBinding(identifier: "project.missing"),
            ]),
            for: entity
        )

        let report = adapter.applyProjectScriptCatalog(.builtIn)
        let before = adapter.scene.localTransform(for: entity)?.rotation
        _ = adapter.tickScene(deltaTime: 0.5)
        let after = adapter.scene.localTransform(for: entity)?.rotation

        #expect(report.unresolvedBindings.count == 1)
        #expect(report.unresolvedBindings[0].contains("project.missing"))
        #expect(before != after)
    }

    @Test("stable script identifiers survive scene JSON round trips")
    func manifestRoundTrip() throws {
        let source = EditorSceneAdapter()
        _ = source.applyProjectScriptCatalog(.builtIn)
        let entity = try #require(source.scene.roots().first)
        _ = source.scene.setComponent(
            ScriptComponent(ScriptBinding(identifier: "guava.mover",
                                          parametersJSON: #"{"velocity":[2,0,0]}"#)),
            for: entity
        )
        let data = try JSONEncoder().encode(source.manifest())
        let decoded = try JSONDecoder().decode(EditorSceneManifest.self, from: data)
        let restored = EditorSceneAdapter()
        _ = restored.applyProjectScriptCatalog(.builtIn)
        _ = restored.load(manifest: decoded, notify: false)
        let restoredEntity = try #require(restored.scene.roots().first)

        let binding = try #require(
            restored.scene.component(ScriptComponent.self, for: restoredEntity)?.bindings.first
        )
        #expect(binding.identifier == "guava.mover")
        #expect(restored.scene.resource(InputActionMap.self)?.bindings["jump"]?
            .contains(.key(Scancode.space)) == true)
        let before = restored.scene.localTransform(for: restoredEntity)?.translation.x
        _ = restored.tickScene(deltaTime: 0.5)
        let after = restored.scene.localTransform(for: restoredEntity)?.translation.x
        #expect(after == before.map { $0 + 1 })
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("guava-script-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeCatalog(_ json: String, to root: URL) throws {
        let url = root.appendingPathComponent(ProjectScriptCatalog.relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url, options: [.atomic])
    }
}
