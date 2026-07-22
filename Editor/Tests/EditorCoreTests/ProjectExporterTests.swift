@testable import EditorCore
import Foundation
import SceneRuntime
import Testing

@Suite("ProjectExporter", .serialized)
struct ProjectExporterTests {

    private func tempDir() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("guava-export-\(UUID().uuidString)", isDirectory: true)
        return url
    }

    @Test("export writes a descriptor, asset list, and player-loadable scene")
    func exportWritesBundle() throws {
        let source = EditorSceneAdapter()
        let manifest = source.manifest(selectedEntityID: source.defaultSelectionID)
        let output = tempDir()
        defer { try? FileManager.default.removeItem(at: output) }

        let descriptor = try ProjectExporter.export(manifest: manifest, appName: "Demo", to: output)
        #expect(descriptor.appName == "Demo")
        #expect(descriptor.entityCount == manifest.entityCount)
        #expect(descriptor.schemaVersion == ProjectExporter.schemaVersion)

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: output.appendingPathComponent("build.json").path))
        #expect(fm.fileExists(atPath: output.appendingPathComponent("assets.json").path))
        // Scene is written where the player's project loader reads it.
        let sceneURL = GameSaveDocument.url(slot: ProjectExporter.sceneSlot, projectDirectory: output.path)
        #expect(fm.fileExists(atPath: sceneURL.path))

        // The descriptor reads back identically.
        #expect(try ProjectExporter.readDescriptor(from: output) == descriptor)
    }

    @Test("exported scene round-trips: a fresh adapter loads the same entity count")
    func exportedSceneIsLoadable() throws {
        let source = EditorSceneAdapter()
        let manifest = source.manifest(selectedEntityID: source.defaultSelectionID)
        let output = tempDir()
        defer { try? FileManager.default.removeItem(at: output) }

        _ = try ProjectExporter.export(manifest: manifest, appName: "Demo", to: output)

        // Load exactly the way GameApplication does: GameSaveDocument at slot 0.
        let sceneURL = GameSaveDocument.url(slot: ProjectExporter.sceneSlot, projectDirectory: output.path)
        let doc = try #require(try GameSaveDocument.read(from: sceneURL))
        let restored = EditorSceneAdapter()
        let result = restored.load(manifest: doc.manifest)
        #expect(result.entityCount == manifest.entityCount)
    }

    @Test("asset list captures referenced assets")
    func exportRecordsAssets() throws {
        let source = EditorSceneAdapter()
        let manifest = source.manifest(selectedEntityID: source.defaultSelectionID)
        let output = tempDir()
        let project = tempDir()
        defer {
            try? FileManager.default.removeItem(at: output)
            try? FileManager.default.removeItem(at: project)
        }
        let modelURL = project.appendingPathComponent("models/barrel.glb")
        try FileManager.default.createDirectory(at: modelURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: modelURL)

        let assets = [
            EditorAsset(id: "a1", name: "Barrel", relativePath: "models/barrel.glb",
                        absolutePath: modelURL.path, kind: .glb, meshIndex: 3),
        ]
        let descriptor = try ProjectExporter.export(manifest: manifest, appName: "Demo",
                                                    assets: assets, to: output)
        #expect(descriptor.assetCount == 1)

        let data = try Data(contentsOf: output.appendingPathComponent("assets.json"))
        let list = try JSONDecoder().decode(ProjectExportAssetList.self, from: data)
        #expect(list.assets.count == 1)
        #expect(list.assets.first?.id == "a1")
        #expect(list.assets.first?.relativePath == "models/barrel.glb")
    }

    @Test("export copies model dependencies and audio resources")
    func exportCopiesRuntimeResources() throws {
        let project = tempDir()
        let output = project.appendingPathComponent("export", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: project) }
        let modelDirectory = project.appendingPathComponent("Assets/Models", isDirectory: true)
        let audioDirectory = project.appendingPathComponent("Assets/Audio", isDirectory: true)
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        let modelURL = modelDirectory.appendingPathComponent("ship.gltf")
        try Data(#"{"asset":{"version":"2.0"},"buffers":[{"uri":"ship.bin","byteLength":4}],"images":[{"uri":"textures/albedo.png"}]}"#.utf8)
            .write(to: modelURL)
        try Data([0, 1, 2, 3]).write(to: modelDirectory.appendingPathComponent("ship.bin"))
        try FileManager.default.createDirectory(at: modelDirectory.appendingPathComponent("textures"),
                                                withIntermediateDirectories: true)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(
            to: modelDirectory.appendingPathComponent("textures/albedo.png")
        )
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: audioDirectory.appendingPathComponent("theme.wav"))
        let asset = EditorAsset(id: "Assets/Models/ship.gltf",
                                name: "ship",
                                relativePath: "Assets/Models/ship.gltf",
                                absolutePath: modelURL.path,
                                kind: .gltf,
                                meshIndex: 9)

        _ = try ProjectExporter.export(manifest: EditorSceneAdapter().manifest(),
                                       appName: "Demo",
                                       assets: [asset],
                                       sourceProjectDirectory: project,
                                       to: output)

        #expect(FileManager.default.fileExists(
            atPath: output.appendingPathComponent("Assets/Models/ship.gltf").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: output.appendingPathComponent("Assets/Models/ship.bin").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: output.appendingPathComponent("Assets/Models/textures/albedo.png").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: output.appendingPathComponent("Assets/Audio/theme.wav").path
        ))
    }

    @Test("re-export replaces stale bundle contents")
    func exportReplacesStaleContents() throws {
        let project = tempDir()
        let output = project.appendingPathComponent("export", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: project) }
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let sourceURL = project.appendingPathComponent("old.glb")
        try Data([1, 2, 3]).write(to: sourceURL)
        let asset = EditorAsset(id: "old.glb", name: "old", relativePath: "old.glb",
                                absolutePath: sourceURL.path, kind: .glb, meshIndex: 2)
        let manifest = EditorSceneAdapter().manifest()

        _ = try ProjectExporter.export(manifest: manifest, appName: "Demo",
                                       assets: [asset], to: output)
        #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("old.glb").path))

        _ = try ProjectExporter.export(manifest: manifest, appName: "Demo", to: output)
        #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("old.glb").path))
    }
}
