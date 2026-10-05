import Foundation
import AssetPipeline
import GuavaUIRuntime
import IntentRuntime
import RenderBackend
import SceneRuntime
import ScriptRuntime
import SIMDCompat

public struct EditorSceneManifestCharacterController: Codable, Sendable, Equatable {
    public let radius: Float
    public let standingHalfHeight: Float
    public let crouchingHalfHeight: Float
    public let center: EditorSceneManifestVector3
    public let maxSlopeDegrees: Float
    public let stepHeight: Float
    public let skinWidth: Float
    public let mass: Float
    public let maxStrength: Float
    public let gravityScale: Float
    public let layerID: UInt16
    public let layerMask: UInt16

    public init(_ component: CharacterController) {
        radius = component.radius
        standingHalfHeight = component.standingHalfHeight
        crouchingHalfHeight = component.crouchingHalfHeight
        center = EditorSceneManifestVector3(component.center)
        maxSlopeDegrees = component.maxSlopeDegrees
        stepHeight = component.stepHeight
        skinWidth = component.skinWidth
        mass = component.mass
        maxStrength = component.maxStrength
        gravityScale = component.gravityScale
        layerID = component.layerID
        layerMask = component.layerMask
    }

    var component: CharacterController {
        CharacterController(
            radius: radius,
            standingHalfHeight: standingHalfHeight,
            crouchingHalfHeight: crouchingHalfHeight,
            center: center.simdValue,
            maxSlopeDegrees: maxSlopeDegrees,
            stepHeight: stepHeight,
            skinWidth: skinWidth,
            mass: mass,
            maxStrength: maxStrength,
            gravityScale: gravityScale,
            layerID: layerID,
            layerMask: layerMask
        )
    }
}
