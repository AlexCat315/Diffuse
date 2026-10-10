/// Identity token for a component that has no Swift type. `ObjectIdentifier` of a
/// retained instance is unique among live tokens, which is what `ComponentRegistry`
/// needs to keep two document schemas apart.
private final class DocumentComponentIdentity: @unchecked Sendable {}

/// Builds schemas for components declared by data — plugin declarations, script
/// modules — whose storage is the authored document itself.
public enum DocumentComponentSchema {
    public static func make(typeID: String,
                            displayName: String,
                            category: ComponentCategory,
                            defaultDocument: ComponentValue,
                            configure: (inout ComponentSchema) -> Void = { _ in }) -> ComponentSchema {
        let identity = DocumentComponentIdentity()
        var schema = ComponentSchema(
            documentTypeID: typeID,
            identity: ObjectIdentifier(identity),
            displayName: displayName,
            category: category,
            defaultDocument: defaultDocument)
        // The closures keep `identity` alive, so its identifier stays unique.
        configure(&schema)
        return schema
    }
}

extension ComponentSchema {
    /// Memberwise document-backed initializer. `identity` must be unique among the
    /// registry's schemas; `DocumentComponentSchema.make` allocates one.
    public init(documentTypeID typeID: String,
                identity: ObjectIdentifier,
                displayName: String,
                category: ComponentCategory,
                defaultDocument: ComponentValue) {
        self.componentTypeID = identity
        self.runtimeTypeName = "document:\(typeID)"
        self.typeID = typeID
        self.displayName = displayName
        self.category = category
        self.has = { world, entity in world.hasDocumentComponent(typeID, for: entity) }
        self.encode = { world, entity, _ in world.documentComponent(typeID, for: entity) }
        self.decode = { value, entity, _, world in
            _ = world.setDocumentComponent(typeID, value, for: entity)
        }
        self.applyEdit = { value, entity, _, world in
            _ = world.setDocumentComponent(typeID, value, for: entity)
        }
        self.makeDefault = { entity, world in
            _ = world.setDocumentComponent(typeID, defaultDocument, for: entity)
        }
        self.remove = { entity, world in
            _ = world.removeDocumentComponent(typeID, from: entity)
        }
    }
}
