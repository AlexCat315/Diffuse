import Foundation
import AssetPipeline
import GuavaUIRuntime
import IntentRuntime
import RenderBackend
import SceneRuntime
import ScriptRuntime
import SIMDCompat

public struct EditorSceneManifestScriptBinding: Codable, Sendable, Equatable {
    public let bindingID: ScriptBindingID
    public let script: UInt64
    public let identifier: String?
    public let isEnabled: Bool
    public let parametersJSON: String

    public init(_ binding: ScriptBinding) {
        self.bindingID = binding.id
        self.script = binding.script.rawValue
        self.identifier = binding.identifier
        self.isEnabled = binding.isEnabled
        self.parametersJSON = binding.parametersJSON
    }

    var binding: ScriptBinding {
        ScriptBinding(ScriptHandle(rawValue: script),
                      id: bindingID,
                      identifier: identifier,
                      isEnabled: isEnabled,
                      parametersJSON: parametersJSON)
    }

    private enum CodingKeys: String, CodingKey {
        case bindingID, script, identifier, isEnabled, parametersJSON
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bindingID = try container.decodeIfPresent(ScriptBindingID.self, forKey: .bindingID)
            ?? ScriptBindingID()
        script = try container.decodeIfPresent(UInt64.self, forKey: .script) ?? 0
        identifier = try container.decodeIfPresent(String.self, forKey: .identifier)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        parametersJSON = try container.decodeIfPresent(String.self, forKey: .parametersJSON) ?? "{}"
    }
}

public struct EditorSceneManifestScript: Codable, Sendable, Equatable {
    public let bindings: [EditorSceneManifestScriptBinding]

    public init(_ component: ScriptComponent) {
        self.bindings = component.bindings.map(EditorSceneManifestScriptBinding.init)
    }

    var component: ScriptComponent {
        ScriptComponent(bindings: bindings.map(\.binding))
    }
}
