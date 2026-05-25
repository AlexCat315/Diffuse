import Foundation

public enum PerceptionSchemaValidator {
    private static let supportedResultSchemas: Set<String> = [
        "guava.perception.result.v1",
    ]
    private static let supportedManifestSchemas: Set<String> = [
        "guava.perception.model_manifest.v1",
    ]

    public enum ValidationError: Error, CustomStringConvertible, Sendable {
        case unsupportedSchemaVersion(String)
        case emptyModelID
        case emptyInputContract
        case emptyOutputContract

        public var description: String {
            switch self {
            case let .unsupportedSchemaVersion(v):
                return "Unsupported schema version '\(v)'"
            case .emptyModelID:
                return "Manifest modelID must not be empty"
            case .emptyInputContract:
                return "Manifest inputContract must not be empty"
            case .emptyOutputContract:
                return "Manifest outputContract must not be empty"
            }
        }
    }

    public static func validate(_ result: PerceptionResult) throws {
        guard supportedResultSchemas.contains(result.schemaVersion) else {
            throw ValidationError.unsupportedSchemaVersion(result.schemaVersion)
        }
    }

    public static func validate(_ manifest: PerceptionModelManifest) throws {
        guard supportedManifestSchemas.contains(manifest.schemaVersion) else {
            throw ValidationError.unsupportedSchemaVersion(manifest.schemaVersion)
        }
        guard !manifest.modelID.isEmpty else { throw ValidationError.emptyModelID }
        guard !manifest.inputContract.isEmpty else { throw ValidationError.emptyInputContract }
        guard !manifest.outputContract.isEmpty else { throw ValidationError.emptyOutputContract }
    }
}
