import Foundation
import SceneRuntime

extension SceneSerializer {

    /// Serializes a full scene including ScriptComponent bindings.
    /// Numeric script handles are NOT persisted because they are process-local. Stable
    /// identifiers, parameters and enabled flags are preserved. Script components flow
    /// through the uniform components loop once the script codec is registered, so the
    /// document no longer depends on an index-aligned post-processing pass.
    public static func serializeFull(_ scene: SceneRuntime) throws -> Data {
        var documentScene = scene
        documentScene.componentRegistry.registerScriptCodec()
        return try serialize(documentScene)
    }

    /// Deserializes a scene and restores ScriptComponent bindings.
    /// Script handles are set to rawValue 0 and resolve through their stable identifiers.
    public static func deserializeFull(_ data: Data, into scene: inout SceneRuntime) throws {
        scene.componentRegistry.registerScriptCodec()
        _ = try deserialize(data, into: &scene)
    }
}

public extension Prefab {
    /// Native-host counterpart to ScriptContext.instantiate, including script bindings.
    /// Registering the script codec before instantiation restores them through the same
    /// decode loop the scene serializer uses.
    @discardableResult
    func instantiateFull(into scene: inout SceneRuntime,
                         parent: EntityID? = nil,
                         transform: LocalTransform? = nil) throws -> EntityID? {
        scene.componentRegistry.registerScriptCodec()
        return try instantiate(into: &scene, parent: parent, transform: transform)
    }

    /// Captures the hierarchy and stable script references as a reusable gameplay prefab.
    static func captureFull(from scene: SceneRuntime, root: EntityID) throws -> Prefab? {
        var documentScene = scene
        documentScene.componentRegistry.registerScriptCodec()
        return try capture(from: documentScene, root: root)
    }
}