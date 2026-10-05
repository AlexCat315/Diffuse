import Foundation
import AssetPipeline
import GuavaUIRuntime
import IntentRuntime
import RenderBackend
import SceneRuntime
import ScriptRuntime
import SIMDCompat

public struct EditorSceneManifestDestructible: Codable, Sendable, Equatable {
    public let assetResourceID: String
    public let damageThreshold: Float
    public let impulseThreshold: Float
    public let fragmentBudget: Int
    public let maximumFragmentLifetimeSeconds: Float
    public let sleepingRecycleDelaySeconds: Float
    public let separationImpulse: Float
    public let isEnabled: Bool

    public init(_ destructible: Destructible) {
        assetResourceID = destructible.assetResourceID
        damageThreshold = destructible.damageThreshold
        impulseThreshold = destructible.impulseThreshold
        fragmentBudget = destructible.fragmentBudget
        maximumFragmentLifetimeSeconds = destructible.maximumFragmentLifetimeSeconds
        sleepingRecycleDelaySeconds = destructible.sleepingRecycleDelaySeconds
        separationImpulse = destructible.separationImpulse
        isEnabled = destructible.isEnabled
    }

    var component: Destructible {
        Destructible(
            assetResourceID: assetResourceID,
            damageThreshold: damageThreshold,
            impulseThreshold: impulseThreshold,
            fragmentBudget: fragmentBudget,
            maximumFragmentLifetimeSeconds: maximumFragmentLifetimeSeconds,
            sleepingRecycleDelaySeconds: sleepingRecycleDelaySeconds,
            separationImpulse: separationImpulse,
            isEnabled: isEnabled
        )
    }
}
