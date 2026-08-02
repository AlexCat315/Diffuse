import Foundation
import Testing
@testable import EditorApp

@Suite("Asset import file replacement")
struct AssetImportFileCopierTests {
    @Test("Re-import replaces an existing asset only after staging succeeds")
    func replacesExistingAsset() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("guava-asset-reimport-\(UUID().uuidString)")
        let source = directory.appendingPathComponent("source/model.glb")
        let destination = directory.appendingPathComponent("project/model.glb")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("new asset".utf8).write(to: source)
        try Data("old asset".utf8).write(to: destination)

        try AssetImportFileCopier.copyReplacing(source: source, destination: destination)

        #expect(try Data(contentsOf: destination) == Data("new asset".utf8))
        let siblings = try FileManager.default.contentsOfDirectory(
            at: destination.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        #expect(!siblings.contains { $0.lastPathComponent.contains(".import-") })
    }

    @Test("A failed re-import preserves the existing asset")
    func failedCopyPreservesExistingAsset() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("guava-asset-reimport-failure-\(UUID().uuidString)")
        let missingSource = directory.appendingPathComponent("missing/model.glb")
        let destination = directory.appendingPathComponent("project/model.glb")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let original = Data("last known good asset".utf8)
        try original.write(to: destination)

        #expect(throws: (any Error).self) {
            try AssetImportFileCopier.copyReplacing(source: missingSource, destination: destination)
        }

        #expect(try Data(contentsOf: destination) == original)
    }

    @Test("First import creates nested destination directories")
    func createsNestedDestination() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("guava-asset-first-import-\(UUID().uuidString)")
        let source = directory.appendingPathComponent("source.png")
        let destination = directory.appendingPathComponent("project/textures/ui/source.png")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload = Data([0, 1, 2, 3])
        try payload.write(to: source)

        try AssetImportFileCopier.copyReplacing(source: source, destination: destination)

        #expect(try Data(contentsOf: destination) == payload)
    }
}
