import Foundation

public enum GameSaveError: Error, Equatable {
    case invalidFormat
    case unsupportedVersion(Int)
}

/// A savegame envelope: a snapshot of the live scene paired with an optional game-defined
/// state payload (score, inventory, quest flags…) and free-form metadata. The whole thing
/// serializes to a single JSON document, so games get save/load without having to make every
/// runtime resource serializable — they encode whatever `Codable` state they care about.
///
/// The embedded scene is captured with `SceneSerializer`, so it reflects the *current* runtime
/// transforms and components, not just the authored layout.
public struct GameSave: Sendable, Equatable {
    public static let currentVersion = 1

    /// Scene document in `SceneSerializer` format.
    public var scene: Data
    /// Optional game-state document (any JSON), or nil when only the scene is saved.
    public var state: Data?
    public var metadata: [String: String]

    public init(scene: Data, state: Data? = nil, metadata: [String: String] = [:]) {
        self.scene = scene
        self.state = state
        self.metadata = metadata
    }

    // MARK: - Capture

    /// Captures the live scene only.
    public static func capture(scene: SceneRuntime, metadata: [String: String] = [:]) throws -> GameSave {
        GameSave(scene: try SceneSerializer.serialize(scene), metadata: metadata)
    }

    /// Captures the live scene plus an encodable game-state payload.
    public static func capture<State: Encodable>(scene: SceneRuntime,
                                                 state: State,
                                                 metadata: [String: String] = [:]) throws -> GameSave {
        GameSave(scene: try SceneSerializer.serialize(scene),
                 state: try JSONEncoder().encode(state),
                 metadata: metadata)
    }

    // MARK: - Serialize

    /// Encodes scene + state + metadata into one self-describing save document.
    public func serialized() throws -> Data {
        var root: [String: Any] = [
            "version": Self.currentVersion,
            "metadata": metadata,
            "scene": try JSONSerialization.jsonObject(with: scene, options: [.fragmentsAllowed]),
        ]
        if let state {
            root["state"] = try JSONSerialization.jsonObject(with: state, options: [.fragmentsAllowed])
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    /// Parses a save document produced by `serialized()`.
    public static func load(_ data: Data) throws -> GameSave {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GameSaveError.invalidFormat
        }
        let version = (root["version"] as? NSNumber)?.intValue ?? 0
        guard version == currentVersion else { throw GameSaveError.unsupportedVersion(version) }
        guard let sceneObj = root["scene"] else { throw GameSaveError.invalidFormat }

        let sceneData = try JSONSerialization.data(withJSONObject: sceneObj, options: [.fragmentsAllowed])
        let metadata = (root["metadata"] as? [String: String]) ?? [:]
        var stateData: Data?
        if let stateObj = root["state"] {
            stateData = try JSONSerialization.data(withJSONObject: stateObj, options: [.fragmentsAllowed])
        }
        return GameSave(scene: sceneData, state: stateData, metadata: metadata)
    }

    // MARK: - Restore

    /// Restores the saved scene into `scene` (entities are appended).
    public func restoreScene(into scene: inout SceneRuntime) throws {
        try SceneSerializer.deserialize(self.scene, into: &scene)
    }

    /// Decodes the game-state payload, or nil if the save carried no state.
    public func decodeState<State: Decodable>(_ type: State.Type) throws -> State? {
        guard let state else { return nil }
        return try JSONDecoder().decode(State.self, from: state)
    }
}
