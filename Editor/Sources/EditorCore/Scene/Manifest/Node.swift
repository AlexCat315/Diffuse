import SceneRuntime

/// Scene nodes keep hierarchy and editor identity; every authored component uses
/// the runtime registry's document value and relocatable reference indices.
public struct EditorSceneManifestNode: Codable, Sendable, Equatable {
    public let id: UInt64
    public let name: String
    public let kind: String
    public let localTransform: EditorSceneManifestMatrix?
    public var components: [ManifestComponent] = []
    public var children: [EditorSceneManifestNode] = []

    public init(id: UInt64, name: String, kind: String,
                localTransform: EditorSceneManifestMatrix? = nil,
                components: [ManifestComponent] = [], children: [EditorSceneManifestNode] = []) {
        self.id = id
        self.name = name
        self.kind = kind
        self.localTransform = localTransform
        self.components = components
        self.children = children
    }

    private enum CodingKeys: String, CodingKey { case id, name, kind, localTransform, components, children }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UInt64.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(String.self, forKey: .kind)
        localTransform = try container.decodeIfPresent(EditorSceneManifestMatrix.self, forKey: .localTransform)
        components = try container.decodeIfPresent([ManifestComponent].self, forKey: .components) ?? []
        children = try container.decodeIfPresent([EditorSceneManifestNode].self, forKey: .children) ?? []
    }
}
