@testable import EditorCore
import Foundation
import SceneRuntime
import Testing

@Suite("EditorAssetFileWorkflow", .serialized)
struct EditorAssetFileWorkflowTests {
    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("guava-file-workflow-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test("moving a model preserves shared dependencies and updates scene and script references")
    func moveModel() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Content/old/model.gltf")
        let destination = root.appendingPathComponent("Content/new/renamed.gltf")
        try write(#"{"buffers":[{"uri":"mesh.bin"}],"images":[{"uri":"textures/color.png"}]}"#, to: source)
        try write("mesh", to: source.deletingLastPathComponent().appendingPathComponent("mesh.bin"))
        try write("image", to: source.deletingLastPathComponent().appendingPathComponent("textures/color.png"))
        let scene = root.appendingPathComponent(".guava/scene.json")
        try write("{\"assetID\":\"Content/old/model.gltf\",\"absolutePath\":\"\(source.path)\"}", to: scene)
        let script = root.appendingPathComponent("Scripts/Spawn.swift")
        try write(#"let asset = "Content/old/model.gltf""#, to: script)
        let references = EditorAssetFileWorkflow.referenceFiles(to: source, within: root)
            .map { $0.resolvingSymlinksInPath() }
        #expect(Set(references) == Set([scene, script].map { $0.resolvingSymlinksInPath() }))

        _ = try EditorAssetFileWorkflow.relocate(from: source, to: destination, within: root)

        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(try Data(contentsOf: root.appendingPathComponent("Content/new/mesh.bin")) == Data("mesh".utf8))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Content/old/mesh.bin").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Content/new/textures/color.png").path))
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: scene)) as? [String: String])
        #expect(json["assetID"] == "Content/new/renamed.gltf")
        #expect(json["absolutePath"] == destination.path)
        #expect(try String(contentsOf: script, encoding: .utf8) == #"let asset = "Content/new/renamed.gltf""#)
    }

    @Test("renaming a texture updates percent-encoded glTF URI references")
    func textureURI() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Content/textures/old color.png")
        let destination = root.appendingPathComponent("Content/shared/new color.png")
        try write("image", to: source)
        let model = root.appendingPathComponent("Content/model.gltf")
        try write(#"{"images":[{"uri":"textures/old%20color.png"}]}"#, to: model)
        _ = try EditorAssetFileWorkflow.relocate(from: source, to: destination, within: root)
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: model)) as? [String: [[String: String]]])
        #expect(json["images"]?.first?["uri"] == "shared/new%20color.png")
    }

    @Test("moving a texture then its model preserves parent-relative dependencies")
    func moveTextureThenModel() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = root.appendingPathComponent("Content/Models/ship.gltf")
        let texture = root.appendingPathComponent("Content/Models/textures/color.png")
        let sharedTexture = root.appendingPathComponent("Content/shared/color.png")
        try write(#"{"buffers":[{"uri":"../buffers/mesh.bin"}],"images":[{"uri":"textures/color.png"}]}"#, to: model)
        try write("image", to: texture)
        try write("buffer", to: root.appendingPathComponent("Content/buffers/mesh.bin"))
        _ = try EditorAssetFileWorkflow.relocate(from: texture, to: sharedTexture, within: root)

        let movedModel = root.appendingPathComponent("Scenes/new/ship.gltf")
        _ = try EditorAssetFileWorkflow.relocate(from: model, to: movedModel, within: root)

        #expect(try Data(contentsOf: root.appendingPathComponent("Scenes/shared/color.png")) == Data("image".utf8))
        #expect(try Data(contentsOf: root.appendingPathComponent("Scenes/buffers/mesh.bin")) == Data("buffer".utf8))
        #expect(FileManager.default.fileExists(atPath: sharedTexture.path))
        let files = AssetImportResolver.resolve(movedModel, projectRoot: root)
        #expect(files.map(\.relativePath) == ["ship.gltf", "../buffers/mesh.bin", "../shared/color.png"])
        #expect(files.allSatisfy { FileManager.default.fileExists(atPath: $0.source.path) })
    }

    @Test("conflicting dependencies and out-of-project destinations leave the source intact")
    func rejectsInvalidMoves() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("old/model.gltf")
        try write(#"{"buffers":[{"uri":"mesh.bin"}]}"#, to: source)
        try write("original", to: root.appendingPathComponent("old/mesh.bin"))
        try write("different", to: root.appendingPathComponent("new/mesh.bin"))
        #expect(throws: (any Error).self) {
            try EditorAssetFileWorkflow.relocate(from: source, to: root.appendingPathComponent("new/model.gltf"), within: root)
        }
        #expect(throws: (any Error).self) {
            try EditorAssetFileWorkflow.relocate(from: source, to: root.appendingPathComponent("../escaped.gltf"), within: root)
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try String(contentsOf: root.appendingPathComponent("new/mesh.bin"), encoding: .utf8) == "different")
    }

    @Test("restoring a missing model includes its dependencies and permits binary dependency repair")
    func restoreDependencies() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("external/model.gltf")
        try write(#"{"buffers":[{"uri":"mesh.bin"}]}"#, to: source)
        try write("buffer", to: root.appendingPathComponent("external/mesh.bin"))
        let project = root.appendingPathComponent("project")
        let target = project.appendingPathComponent("Content/restored.gltf")
        try EditorAssetFileWorkflow.restoreMissing(from: source, to: target, within: project)
        #expect(FileManager.default.fileExists(atPath: target.path))
        #expect(try Data(contentsOf: project.appendingPathComponent("Content/mesh.bin")) == Data("buffer".utf8))
        try EditorAssetFileWorkflow.restoreMissing(from: root.appendingPathComponent("external/mesh.bin"),
            to: project.appendingPathComponent("Content/another.bin"), within: project)
        #expect(FileManager.default.fileExists(atPath: project.appendingPathComponent("Content/another.bin").path))
    }

    @Test("failed validation rolls back restored files while preserving shared dependencies")
    func restoreRollback() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("external/model.gltf")
        try write(#"{"buffers":[{"uri":"shared.bin"},{"uri":"new.bin"}]}"#, to: source)
        try write("shared", to: root.appendingPathComponent("external/shared.bin"))
        try write("new", to: root.appendingPathComponent("external/new.bin"))
        let project = root.appendingPathComponent("project")
        try write("shared", to: project.appendingPathComponent("Content/shared.bin"))
        let target = project.appendingPathComponent("Content/model.gltf")
        #expect(throws: (any Error).self) {
            try EditorAssetFileWorkflow.restoreMissing(from: source, to: target, within: project) {
                throw EditorAssetFileWorkflow.Failure("Invalid model")
            }
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(!FileManager.default.fileExists(atPath: project.appendingPathComponent("Content/new.bin").path))
        #expect(try Data(contentsOf: project.appendingPathComponent("Content/shared.bin")) == Data("shared".utf8))
    }

    @Test("undoing a scene edit after a file move keeps the new asset identity")
    func historyReferences() throws {
        let adapter = EditorSceneAdapter(seedPreviewScene: false)
        let old = EditorAsset(id: "Content/old.glb", name: "Old", relativePath: "Content/old.glb",
                              absolutePath: "/project/Content/old.glb", kind: .glb, meshIndex: 0)
        let entity = try #require(adapter.spawnEntity(from: old))
        let new = EditorAsset(id: "Content/new.glb", name: "New", relativePath: "Content/new.glb",
                              absolutePath: "/project/Content/new.glb", kind: .glb, meshIndex: 0)
        let name = try #require(adapter.inspectorSections(for: entity).first { $0.id == "general" }?
            .fields.first { $0.id == "name" })
        guard case .text(let binding) = name.value else { Issue.record("Expected name binding"); return }
        binding.wrappedValue = "Edited name"
        adapter.relocateAssetReferences(from: old.id, to: new)
        #expect(adapter.assetReferencedEntityIDs(old.id).isEmpty)
        #expect(adapter.assetReferencedEntityIDs(new.id) == [entity])
        #expect(adapter.undoEdit())
        #expect(adapter.assetReferencedEntityIDs(new.id) == [entity])
        #expect(adapter.redoEdit())
        #expect(adapter.assetReferencedEntityIDs(new.id) == [entity])
    }
}
