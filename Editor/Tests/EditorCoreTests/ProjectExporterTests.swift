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
        defer { try? FileManager.default.removeItem(at: output) }

        let assets = [
            EditorAsset(id: "a1", name: "Barrel", relativePath: "models/barrel.glb",
                        absolutePath: "/proj/models/barrel.glb", kind: .glb, meshIndex: 3),
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
}
