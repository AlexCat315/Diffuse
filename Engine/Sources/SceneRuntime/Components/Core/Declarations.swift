import Foundation

/// Bounds applied to component declarations that arrive from outside the process.
public struct ComponentDeclarationLimits: Sendable, Equatable {
    public var maximumPayloadBytes = 1 << 20
    public var maximumComponents = 32
    public var maximumFieldsPerComponent = 64

    public init() {}
}

public enum ComponentDeclarationError: Error, Equatable {
    /// The payload is not a JSON array of component descriptions.
    case invalidPayload
    case payloadTooLarge(Int)
    case tooManyComponents(Int)
    case emptyTypeID
    case duplicateTypeID(String)
    /// Declared components must be namespaced, so they can never shadow a
    /// built-in type ID such as `collider`.
    case unnamespacedTypeID(String)
    case missingDefaults(String)
    case tooManyFields(String, Int)
}

/// Decodes component declarations that travel as data — plugin output, module
/// manifests — into descriptions the registry can install.
public enum ComponentDeclarations {
    public static func decode(_ data: Data,
                              limits: ComponentDeclarationLimits = ComponentDeclarationLimits()) throws -> [ComponentDescription] {
        guard data.count <= limits.maximumPayloadBytes else {
            throw ComponentDeclarationError.payloadTooLarge(data.count)
        }
        let decoded: [ComponentDescription]
        do { decoded = try JSONDecoder().decode([ComponentDescription].self, from: data) }
        catch { throw ComponentDeclarationError.invalidPayload }
        guard decoded.count <= limits.maximumComponents else {
            throw ComponentDeclarationError.tooManyComponents(decoded.count)
        }
        var seen: Set<String> = []
        for description in decoded {
            guard !description.typeID.isEmpty else { throw ComponentDeclarationError.emptyTypeID }
            let parts = description.typeID.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
                throw ComponentDeclarationError.unnamespacedTypeID(description.typeID)
            }
            guard seen.insert(description.typeID).inserted else {
                throw ComponentDeclarationError.duplicateTypeID(description.typeID)
            }
            guard let defaults = description.defaults, case .object = defaults else {
                throw ComponentDeclarationError.missingDefaults(description.typeID)
            }
            guard description.fields.count <= limits.maximumFieldsPerComponent else {
                throw ComponentDeclarationError.tooManyFields(description.typeID, description.fields.count)
            }
        }
        return decoded
    }
}

public extension ComponentRegistry {
    /// Installs components described by data. Their storage is the authored
    /// document, so serialization, prefabs, game saves, the generated inspector
    /// form and `componentDescriptions` all work without native code.
    ///
    /// Declarations are untrusted: this throws instead of trapping. Validate with
    /// `ComponentDeclarations.decode(_:limits:)` before installing.
    mutating func register(contentsOf declarations: [ComponentDescription]) throws {
        for description in declarations {
            guard !description.typeID.isEmpty else { throw ComponentDeclarationError.emptyTypeID }
            guard self[description.typeID] == nil else {
                throw ComponentDeclarationError.duplicateTypeID(description.typeID)
            }
            guard let defaults = description.defaults, case .object = defaults else {
                throw ComponentDeclarationError.missingDefaults(description.typeID)
            }
            var schema = DocumentComponentSchema.make(typeID: description.typeID,
                                                      displayName: description.displayName,
                                                      category: description.category,
                                                      defaultDocument: defaults)
            schema.requires = description.requires
            schema.isUserAddable = description.isUserAddable
            schema.inspection.fields = description.fields
            register(schema)
        }
        for description in declarations {
            _ = try requiredSchemas(for: description.typeID)
        }
    }
}
