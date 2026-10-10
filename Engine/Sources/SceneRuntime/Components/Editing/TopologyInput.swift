import Foundation

extension BuiltinComponentCodecs {
    static func normalizeClothChanges(_ previous: ComponentValue, _ changes: ComponentValue) throws -> ComponentValue {
        guard case var .object(fields) = changes, fields["fixedVertexIndices"] != nil else { return changes }
        let merged = try previous.merging(changes)
        try validateVertexIndices(merged.value(at: ["fixedVertexIndices"]), typeID: "cloth")
        guard let dictionary = merged.objectValue else { throw ComponentEditError.invalidValue("cloth") }
        let cloth = deserializeCloth(dictionary)
        fields["fixedVertexIndices"] = .array(cloth.fixedVertexIndices.map { .signedInteger(Int64($0)) })
        return .object(fields)
    }

    static func normalizeSoftBodyMeshChanges(_ previous: ComponentValue, _ changes: ComponentValue) throws -> ComponentValue {
        guard case var .object(fields) = changes else { return changes }
        let merged = try previous.merging(changes)
        if fields["fixedVertexIndices"] != nil {
            try validateVertexIndices(merged.value(at: ["fixedVertexIndices"]), typeID: "softBodyMesh")
            guard let dictionary = merged.objectValue else { throw ComponentEditError.invalidValue("softBodyMesh") }
            let mesh = deserializeSoftBodyMesh(dictionary)
            fields["fixedVertexIndices"] = .array(mesh.fixedVertexIndices.map { .signedInteger(Int64($0)) })
        }
        if case let .string(resource)? = fields["resourceID"] {
            let trimmed = resource.trimmingCharacters(in: .whitespacesAndNewlines)
            fields["resourceID"] = trimmed.isEmpty ? .null : .string(trimmed)
        }
        return .object(fields)
    }

    private static func validateVertexIndices(_ value: ComponentValue?, typeID: String) throws {
        guard let value, let data = try? JSONEncoder().encode(value),
              (try? JSONDecoder().decode([Int].self, from: data)) != nil else {
            throw ComponentEditError.invalidValue(typeID)
        }
    }
}
