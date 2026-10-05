import Foundation
import AssetPipeline
import GuavaUIRuntime
import IntentRuntime
import RenderBackend
import SceneRuntime
import ScriptRuntime
import SIMDCompat

public struct EditorSceneNode: Identifiable {
    public let id: UInt64
    public let name: String
    public let kind: String
    public let children: [EditorSceneNode]

    public init(id: UInt64,
                name: String,
                kind: String,
                children: [EditorSceneNode]) {
        self.id = id
        self.name = name
        self.kind = kind
        self.children = children
    }
}

public struct EditorSceneEntitySummary {
    public let id: UInt64
    public let name: String
    public let kind: String

    public init(id: UInt64, name: String, kind: String) {
        self.id = id
        self.name = name
        self.kind = kind
    }
}
