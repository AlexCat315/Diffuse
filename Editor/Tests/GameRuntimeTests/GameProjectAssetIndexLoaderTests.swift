import EditorCore
import Foundation
@testable import GameRuntime
import Testing

@Suite("Game project asset index loader", .serialized)
struct GameProjectAssetIndexLoaderTests {
    private func temporaryProject() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("guava-player-assets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("missing asset list is valid for development projects")
    func missingListIsEmpty() throws {
        let project = try temporaryProject()
        defer { try? FileManager.default.removeItem(at: project) }

        #expect(try GameProjectAssetIndexLoader.load(projectDirectory: project).isEmpty)
    }

    @Test("loads stable mesh slots and ignores texture slot zero")
    func loadsMeshSlots() throws {
        let project = try temporaryProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let list = ProjectExportAssetList(assets: [
            ProjectExportAsset(id: "mesh", name: "mesh", relativePath: "Assets\\ship.glb",
                               kind: "glb", meshIndex: 7),
            ProjectExportAsset(id: "texture", name: "texture", relativePath: "tex.png",
                               kind: "png", meshIndex: 0),
        ])
        try JSONEncoder().encode(list).write(to: project.appendingPathComponent("assets.json"))

        #expect(try GameProjectAssetIndexLoader.load(projectDirectory: project)
            == ["Assets/ship.glb": 7])
    }

    @Test("existing malformed asset list fails instead of silently remapping meshes")
    func malformedListFails() throws {
        let project = try temporaryProject()
        defer { try? FileManager.default.removeItem(at: project) }
        try Data("not-json".utf8).write(to: project.appendingPathComponent("assets.json"))

        #expect(throws: (any Error).self) {
            _ = try GameProjectAssetIndexLoader.load(projectDirectory: project)
        }
    }

    @Test("export descriptor requires an asset list even when it is empty")
    func exportedProjectRequiresAssetList() throws {
        let project = try temporaryProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let descriptor = ProjectExportDescriptor(
            schemaVersion: ProjectExporter.schemaVersion,
            appName: "Broken",
            exportedAt: "2026-01-01T00:00:00Z",
            entityCount: 0,
            assetCount: 0,
            sceneSlot: 0
        )
        try JSONEncoder().encode(descriptor).write(to: project.appendingPathComponent("build.json"))

        #expect(throws: GameProjectAssetIndexError.missingExportAssetList) {
            _ = try GameProjectAssetIndexLoader.load(projectDirectory: project)
        }
    }

    @Test("duplicate mesh slots are rejected")
    func duplicateMeshSlotsFail() throws {
        let project = try temporaryProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let list = ProjectExportAssetList(assets: [
            ProjectExportAsset(id: "one", name: "one", relativePath: "one.glb",
                               kind: "glb", meshIndex: 4),
            ProjectExportAsset(id: "two", name: "two", relativePath: "two.glb",
                               kind: "glb", meshIndex: 4),
        ])
        try JSONEncoder().encode(list).write(to: project.appendingPathComponent("assets.json"))

        #expect(throws: GameProjectAssetIndexError.duplicateMeshIndex(4)) {
            _ = try GameProjectAssetIndexLoader.load(projectDirectory: project)
        }
    }
}
