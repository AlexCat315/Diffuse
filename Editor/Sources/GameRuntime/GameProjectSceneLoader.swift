import EditorCore
import Foundation

public enum GameProjectSceneLoadError: Error, CustomStringConvertible, Equatable {
    case unsupportedExportVersion(Int)
    case invalidSceneSlot(Int)
    case missingExportedScene(Int)
    case sceneSlotMismatch(expected: Int, actual: Int)
    case entityCountMismatch(expected: Int, actual: Int)

    public var description: String {
        switch self {
        case let .unsupportedExportVersion(version):
            return "unsupported project export version: \(version)"
        case let .invalidSceneSlot(slot):
            return "project export declares an invalid scene slot: \(slot)"
        case let .missingExportedScene(slot):
            return "project export is missing its scene save for slot \(slot)"
        case let .sceneSlotMismatch(expected, actual):
            return "project scene slot mismatch (expected \(expected), found \(actual))"
        case let .entityCountMismatch(expected, actual):
            return "project entity count mismatch (expected \(expected), found \(actual))"
        }
    }
}

/// Loads the startup scene for both exported bundles and development projects.
/// Exported bundles are strict: their descriptor, declared save, slot and entity
/// count must agree. Development projects without `build.json` retain the
/// optional slot-0 behavior used by GuavaPlayer during authoring.
public enum GameProjectSceneLoader {
    public static func load(projectDirectory: URL,
                            fileManager: FileManager = .default) throws -> EditorSceneManifest? {
        let descriptorURL = projectDirectory.appendingPathComponent("build.json")
        let descriptor: ProjectExportDescriptor?
        if fileManager.fileExists(atPath: descriptorURL.path) {
            let decoded = try ProjectExporter.readDescriptor(from: projectDirectory)
            guard decoded.schemaVersion == ProjectExporter.schemaVersion else {
                throw GameProjectSceneLoadError.unsupportedExportVersion(decoded.schemaVersion)
            }
            guard decoded.sceneSlot >= 0 else {
                throw GameProjectSceneLoadError.invalidSceneSlot(decoded.sceneSlot)
            }
            descriptor = decoded
        } else {
            descriptor = nil
        }

        let slot = descriptor?.sceneSlot ?? ProjectExporter.sceneSlot
        let sceneURL = GameSaveDocument.url(slot: slot, projectDirectory: projectDirectory.path)
        guard let document = try GameSaveDocument.read(from: sceneURL) else {
            if descriptor != nil {
                throw GameProjectSceneLoadError.missingExportedScene(slot)
            }
            return nil
        }
        guard document.slot == slot else {
            throw GameProjectSceneLoadError.sceneSlotMismatch(expected: slot, actual: document.slot)
        }
        if let descriptor,
           document.manifest.entityCount != descriptor.entityCount {
            throw GameProjectSceneLoadError.entityCountMismatch(
                expected: descriptor.entityCount,
                actual: document.manifest.entityCount
            )
        }
        return document.manifest
    }
}
