import EditorCore
import Foundation
@testable import GameRuntime
import Testing

@Suite("Game project scene loader", .serialized)
struct GameProjectSceneLoaderTests {
    private func temporaryProject() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("guava-player-scene-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("development project may omit a startup scene")
    func developmentProjectMayHaveNoScene() throws {
        let project = try temporaryProject()
        defer { try? FileManager.default.removeItem(at: project) }

        #expect(try GameProjectSceneLoader.load(projectDirectory: project) == nil)
    }

    @Test("exported project loads its declared scene")
    func exportedProjectLoadsScene() throws {
        let project = try temporaryProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let manifest = EditorSceneAdapter().manifest()
        _ = try ProjectExporter.export(manifest: manifest, appName: "Demo", to: project)

        #expect(try GameProjectSceneLoader.load(projectDirectory: project) == manifest)
    }

    @Test("export descriptor without its declared scene is rejected")
    func missingExportedSceneFails() throws {
        let project = try temporaryProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let descriptor = ProjectExportDescriptor(
            schemaVersion: ProjectExporter.schemaVersion,
            appName: "Broken",
            exportedAt: "2026-01-01T00:00:00Z",
            entityCount: 1,
            assetCount: 0,
            sceneSlot: ProjectExporter.sceneSlot
        )
        try JSONEncoder().encode(descriptor).write(to: project.appendingPathComponent("build.json"))

        #expect(throws: GameProjectSceneLoadError.missingExportedScene(ProjectExporter.sceneSlot)) {
            _ = try GameProjectSceneLoader.load(projectDirectory: project)
        }
    }

    @Test("unsupported export descriptor version is rejected")
    func unsupportedExportVersionFails() throws {
        let project = try temporaryProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let descriptor = ProjectExportDescriptor(
            schemaVersion: ProjectExporter.schemaVersion + 1,
            appName: "Future",
            exportedAt: "2026-01-01T00:00:00Z",
            entityCount: 0,
            assetCount: 0,
            sceneSlot: ProjectExporter.sceneSlot
        )
        try JSONEncoder().encode(descriptor).write(to: project.appendingPathComponent("build.json"))

        #expect(throws: GameProjectSceneLoadError.unsupportedExportVersion(
            ProjectExporter.schemaVersion + 1
        )) {
            _ = try GameProjectSceneLoader.load(projectDirectory: project)
        }
    }
}
