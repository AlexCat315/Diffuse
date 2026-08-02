@testable import EditorApp
import Foundation
import Testing

@Suite("Editor asset import coordinator", .serialized)
struct EditorAssetImportCoordinatorTests {
    @Test("shared import copy includes local glTF dependencies")
    func copiesDependencies() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "guava-editor-import-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        let textures = source.appendingPathComponent("textures", isDirectory: true)
        try FileManager.default.createDirectory(at: textures, withIntermediateDirectories: true)

        let gltf = source.appendingPathComponent("scene.gltf")
        let buffer = source.appendingPathComponent("scene.bin")
        let texture = textures.appendingPathComponent("albedo.png")
        try Data(#"{"buffers":[{"uri":"scene.bin"}],"images":[{"uri":"textures/albedo.png"}]}"#.utf8)
            .write(to: gltf)
        try Data([0, 1, 2, 3]).write(to: buffer)
        try Data([4, 5, 6, 7]).write(to: texture)

        let outcome = EditorAssetImportCoordinator.copyAsset(from: gltf, into: destination)

        #expect(outcome.copied)
        #expect(outcome.missing.isEmpty)
        #expect(outcome.failures.isEmpty)
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("scene.gltf").path))
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("scene.bin").path))
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("textures/albedo.png").path))
    }
}
