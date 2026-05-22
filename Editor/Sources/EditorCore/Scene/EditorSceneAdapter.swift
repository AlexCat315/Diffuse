import Foundation
import AssetPipeline
import GuavaUIRuntime
import IntentRuntime
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

public struct EditorSceneManifestNode: Codable, Sendable, Equatable {
    public let id: UInt64
    public let name: String
    public let kind: String
    public let localTransform: EditorSceneManifestMatrix?
    public let asset: EditorSceneManifestAssetReference?
    public let renderMesh: EditorSceneManifestRenderMesh?
    public let renderMaterial: EditorSceneManifestRenderMaterial?
    public let camera: EditorSceneManifestCamera?
    public let light: EditorSceneManifestLight?
    public let rigidBody: EditorSceneManifestRigidBody?
    public let collider: EditorSceneManifestCollider?
    public let constraint: EditorSceneManifestConstraint?
    public let script: EditorSceneManifestScript?
    public let audioSource: EditorSceneManifestAudioSource?
    public let animationPlayer: EditorSceneManifestAnimationPlayer?
    public let children: [EditorSceneManifestNode]

    public init(id: UInt64,
                name: String,
                kind: String,
                localTransform: EditorSceneManifestMatrix? = nil,
                asset: EditorSceneManifestAssetReference? = nil,
                renderMesh: EditorSceneManifestRenderMesh? = nil,
                renderMaterial: EditorSceneManifestRenderMaterial? = nil,
                camera: EditorSceneManifestCamera? = nil,
                light: EditorSceneManifestLight? = nil,
                rigidBody: EditorSceneManifestRigidBody? = nil,
                collider: EditorSceneManifestCollider? = nil,
                constraint: EditorSceneManifestConstraint? = nil,
                script: EditorSceneManifestScript? = nil,
                audioSource: EditorSceneManifestAudioSource? = nil,
                animationPlayer: EditorSceneManifestAnimationPlayer? = nil,
                children: [EditorSceneManifestNode] = []) {
        self.id = id
        self.name = name
        self.kind = kind
        self.localTransform = localTransform
        self.asset = asset
        self.renderMesh = renderMesh
        self.renderMaterial = renderMaterial
        self.camera = camera
        self.light = light
        self.rigidBody = rigidBody
        self.collider = collider
        self.constraint = constraint
        self.script = script
        self.audioSource = audioSource
        self.animationPlayer = animationPlayer
        self.children = children
    }
}

public struct EditorSceneManifestPhysicsSettings: Codable, Sendable, Equatable {
    public let simulationMode: String
    public let backendKind: String
    public let gravity: EditorSceneManifestVector3
    public let fixedTimeStepSeconds: Double
    public let maxSubstepsPerFrame: Int
    public let allowSleep: Bool

    public init(_ settings: PhysicsSettingsResource) {
        self.simulationMode = settings.simulationMode.rawValue
        self.backendKind = settings.backendKind.rawValue
        self.gravity = EditorSceneManifestVector3(settings.gravity)
        self.fixedTimeStepSeconds = settings.fixedTimeStepSeconds
        self.maxSubstepsPerFrame = settings.maxSubstepsPerFrame
        self.allowSleep = settings.allowSleep
    }

    var settings: PhysicsSettingsResource {
        PhysicsSettingsResource(
            simulationMode: PhysicsSimulationMode(rawValue: simulationMode) ?? .off,
            backendKind: PhysicsBackendKind(rawValue: backendKind) ?? .none,
            gravity: gravity.simdValue,
            fixedTimeStepSeconds: fixedTimeStepSeconds,
            maxSubstepsPerFrame: maxSubstepsPerFrame,
            allowSleep: allowSleep
        )
    }
}

public struct EditorSceneManifest: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let revision: UInt64
    public let entityCount: Int
    public let selectedEntityID: UInt64?
    public let sceneKind: String?
    public let physicsSettings: EditorSceneManifestPhysicsSettings?
    public let projectAssetCount: Int?
    public let lastModifiedAt: String?
    public let roots: [EditorSceneManifestNode]

    public init(schemaVersion: Int = 4,
                revision: UInt64,
                entityCount: Int,
                selectedEntityID: UInt64? = nil,
                sceneKind: String? = nil,
                physicsSettings: EditorSceneManifestPhysicsSettings? = nil,
                projectAssetCount: Int? = nil,
                lastModifiedAt: String? = nil,
                roots: [EditorSceneManifestNode]) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.entityCount = entityCount
        self.selectedEntityID = selectedEntityID
        self.sceneKind = sceneKind
        self.physicsSettings = physicsSettings
        self.projectAssetCount = projectAssetCount
        self.lastModifiedAt = lastModifiedAt
        self.roots = roots
    }
}

public struct EditorSceneManifestLoadResult: Sendable, Equatable {
    public let entityCount: Int
    public let selectedEntityID: UInt64?

    public init(entityCount: Int, selectedEntityID: UInt64?) {
        self.entityCount = entityCount
        self.selectedEntityID = selectedEntityID
    }
}

public struct EditorSceneManifestVector3: Codable, Sendable, Equatable {
    public let x: Float
    public let y: Float
    public let z: Float

    public init(x: Float, y: Float, z: Float) {
        self.x = x
        self.y = y
        self.z = z
    }

    public init(_ value: SIMD3<Float>) {
        self.init(x: value.x, y: value.y, z: value.z)
    }

    var simdValue: SIMD3<Float> {
        SIMD3<Float>(x, y, z)
    }
}

public struct EditorSceneManifestVector4: Codable, Sendable, Equatable {
    public let x: Float
    public let y: Float
    public let z: Float
    public let w: Float

    public init(x: Float, y: Float, z: Float, w: Float) {
        self.x = x
        self.y = y
        self.z = z
        self.w = w
    }

    public init(_ value: SIMD4<Float>) {
        self.init(x: value.x, y: value.y, z: value.z, w: value.w)
    }

    var simdValue: SIMD4<Float> {
        SIMD4<Float>(x, y, z, w)
    }
}

public struct EditorSceneManifestMatrix: Codable, Sendable, Equatable {
    public let rows: [Float]

    public init(rows: [Float]) {
        self.rows = rows
    }

    public init(_ matrix: simd_float4x4) {
        let c0 = matrix.columns.0
        let c1 = matrix.columns.1
        let c2 = matrix.columns.2
        let c3 = matrix.columns.3
        self.rows = [
            c0.x, c1.x, c2.x, c3.x,
            c0.y, c1.y, c2.y, c3.y,
            c0.z, c1.z, c2.z, c3.z,
            c0.w, c1.w, c2.w, c3.w,
        ]
    }

    var simdValue: simd_float4x4? {
        guard rows.count == 16 else { return nil }
        return simd_float4x4(rows: [
            SIMD4<Float>(rows[0], rows[1], rows[2], rows[3]),
            SIMD4<Float>(rows[4], rows[5], rows[6], rows[7]),
            SIMD4<Float>(rows[8], rows[9], rows[10], rows[11]),
            SIMD4<Float>(rows[12], rows[13], rows[14], rows[15]),
        ])
    }

    var localTransform: LocalTransform? {
        simdValue.map(LocalTransform.init(matrix:))
    }
}

public struct EditorSceneManifestAssetReference: Codable, Sendable, Equatable {
    public let assetID: String
    public let name: String
    public let relativePath: String
    public let absolutePath: String
    public let kind: String
    public let meshIndex: Int

    public init(assetID: String,
                name: String,
                relativePath: String,
                absolutePath: String,
                kind: String,
                meshIndex: Int) {
        self.assetID = assetID
        self.name = name
        self.relativePath = relativePath
        self.absolutePath = absolutePath
        self.kind = kind
        self.meshIndex = meshIndex
    }

    public init(_ component: AssetReferenceComponent) {
        self.init(assetID: component.assetID,
                  name: component.name,
                  relativePath: component.relativePath,
                  absolutePath: component.absolutePath,
                  kind: component.kind,
                  meshIndex: component.meshIndex)
    }

    var component: AssetReferenceComponent {
        AssetReferenceComponent(assetID: assetID,
                                name: name,
                                relativePath: relativePath,
                                absolutePath: absolutePath,
                                kind: kind,
                                meshIndex: meshIndex)
    }
}

public struct EditorSceneManifestRenderMesh: Codable, Sendable, Equatable {
    public let meshIndex: Int
    public let isVisible: Bool
    public let colorTint: EditorSceneManifestVector3?
    public let assetID: String?

    public init(meshIndex: Int,
                isVisible: Bool,
                colorTint: EditorSceneManifestVector3? = nil,
                assetID: String? = nil) {
        self.meshIndex = meshIndex
        self.isVisible = isVisible
        self.colorTint = colorTint
        self.assetID = assetID
    }

    public init(_ component: RenderMeshComponent) {
        self.init(meshIndex: component.meshIndex,
                  isVisible: component.isVisible,
                  colorTint: EditorSceneManifestVector3(component.colorTint),
                  assetID: component.assetID)
    }

    var component: RenderMeshComponent {
        RenderMeshComponent(meshIndex: meshIndex,
                            isVisible: isVisible,
                            colorTint: colorTint?.simdValue ?? SIMD3<Float>(1, 1, 1),
                            assetID: assetID)
    }
}

public struct EditorSceneManifestRenderMaterial: Codable, Sendable, Equatable {
    public let baseColorFactor: EditorSceneManifestVector4
    public let baseColorTextureIndex: Int?
    public let normalTextureIndex: Int?
    public let metallicFactor: Float
    public let roughnessFactor: Float
    public let emissiveFactor: EditorSceneManifestVector3

    public init(baseColorFactor: EditorSceneManifestVector4,
                baseColorTextureIndex: Int? = nil,
                normalTextureIndex: Int? = nil,
                metallicFactor: Float,
                roughnessFactor: Float,
                emissiveFactor: EditorSceneManifestVector3) {
        self.baseColorFactor = baseColorFactor
        self.baseColorTextureIndex = baseColorTextureIndex
        self.normalTextureIndex = normalTextureIndex
        self.metallicFactor = metallicFactor
        self.roughnessFactor = roughnessFactor
        self.emissiveFactor = emissiveFactor
    }

    public init(_ component: RenderMaterialComponent) {
        self.init(baseColorFactor: EditorSceneManifestVector4(component.baseColorFactor),
                  baseColorTextureIndex: component.baseColorTextureIndex,
                  normalTextureIndex: component.normalTextureIndex,
                  metallicFactor: component.metallicFactor,
                  roughnessFactor: component.roughnessFactor,
                  emissiveFactor: EditorSceneManifestVector3(component.emissiveFactor))
    }

    var component: RenderMaterialComponent {
        RenderMaterialComponent(baseColorFactor: baseColorFactor.simdValue,
                                baseColorTextureIndex: baseColorTextureIndex,
                                normalTextureIndex: normalTextureIndex,
                                metallicFactor: metallicFactor,
                                roughnessFactor: roughnessFactor,
                                emissiveFactor: emissiveFactor.simdValue)
    }
}

public struct EditorSceneManifestCamera: Codable, Sendable, Equatable {
    public let target: EditorSceneManifestVector3
    public let up: EditorSceneManifestVector3
    public let fovYRadians: Float
    public let near: Float
    public let far: Float
    public let isActive: Bool

    public init(target: EditorSceneManifestVector3,
                up: EditorSceneManifestVector3,
                fovYRadians: Float,
                near: Float,
                far: Float,
                isActive: Bool) {
        self.target = target
        self.up = up
        self.fovYRadians = fovYRadians
        self.near = near
        self.far = far
        self.isActive = isActive
    }

    public init(_ component: CameraComponent) {
        self.init(target: EditorSceneManifestVector3(component.target),
                  up: EditorSceneManifestVector3(component.up),
                  fovYRadians: component.fovYRadians,
                  near: component.near,
                  far: component.far,
                  isActive: component.isActive)
    }

    var component: CameraComponent {
        CameraComponent(target: target.simdValue,
                        up: up.simdValue,
                        fovYRadians: fovYRadians,
                        near: near,
                        far: far,
                        isActive: isActive)
    }
}

public struct EditorSceneManifestLight: Codable, Sendable, Equatable {
    public let type: String
    public let color: EditorSceneManifestVector3
    public let intensity: Float
    public let range: Float
    public let spotInnerAngleDegrees: Float
    public let spotOuterAngleDegrees: Float

    public init(type: String,
                color: EditorSceneManifestVector3,
                intensity: Float,
                range: Float,
                spotInnerAngleDegrees: Float,
                spotOuterAngleDegrees: Float) {
        self.type = type
        self.color = color
        self.intensity = intensity
        self.range = range
        self.spotInnerAngleDegrees = spotInnerAngleDegrees
        self.spotOuterAngleDegrees = spotOuterAngleDegrees
    }

    public init(_ component: LightComponent) {
        self.init(type: component.type.rawValue,
                  color: EditorSceneManifestVector3(component.color),
                  intensity: component.intensity,
                  range: component.range,
                  spotInnerAngleDegrees: component.spotInnerAngleDegrees,
                  spotOuterAngleDegrees: component.spotOuterAngleDegrees)
    }

    var component: LightComponent {
        LightComponent(type: LightType(rawValue: type) ?? .directional,
                       color: color.simdValue,
                       intensity: intensity,
                       range: range,
                       spotInnerAngleDegrees: spotInnerAngleDegrees,
                       spotOuterAngleDegrees: spotOuterAngleDegrees)
    }
}

public struct EditorSceneManifestRigidBody: Codable, Sendable, Equatable {
    public let motionType: String
    public let mass: Float
    public let linearVelocity: EditorSceneManifestVector3
    public let angularVelocity: EditorSceneManifestVector3
    public let accumulatedForce: EditorSceneManifestVector3
    public let accumulatedTorque: EditorSceneManifestVector3
    public let gravityScale: Float
    public let linearDamping: Float
    public let angularDamping: Float
    public let allowSleep: Bool
    public let isSleeping: Bool

    public init(_ component: RigidBody) {
        self.motionType = component.motionType.rawValue
        self.mass = component.mass
        self.linearVelocity = EditorSceneManifestVector3(component.linearVelocity)
        self.angularVelocity = EditorSceneManifestVector3(component.angularVelocity)
        self.accumulatedForce = EditorSceneManifestVector3(component.accumulatedForce)
        self.accumulatedTorque = EditorSceneManifestVector3(component.accumulatedTorque)
        self.gravityScale = component.gravityScale
        self.linearDamping = component.linearDamping
        self.angularDamping = component.angularDamping
        self.allowSleep = component.allowSleep
        self.isSleeping = component.isSleeping
    }

    var component: RigidBody {
        RigidBody(motionType: RigidBodyMotionType(rawValue: motionType) ?? .dynamic,
                  mass: mass,
                  linearVelocity: linearVelocity.simdValue,
                  angularVelocity: angularVelocity.simdValue,
                  accumulatedForce: accumulatedForce.simdValue,
                  accumulatedTorque: accumulatedTorque.simdValue,
                  gravityScale: gravityScale,
                  linearDamping: linearDamping,
                  angularDamping: angularDamping,
                  allowSleep: allowSleep,
                  isSleeping: isSleeping)
    }
}

public struct EditorSceneManifestPhysicsMaterial: Codable, Sendable, Equatable {
    public let friction: Float
    public let restitution: Float
    public let density: Float

    public init(_ material: PhysicsMaterial) {
        self.friction = material.friction
        self.restitution = material.restitution
        self.density = material.density
    }

    var material: PhysicsMaterial {
        PhysicsMaterial(friction: friction, restitution: restitution, density: density)
    }
}

public struct EditorSceneManifestColliderShape: Codable, Sendable, Equatable {
    public let kind: String
    public let halfExtents: EditorSceneManifestVector3?
    public let radius: Float?
    public let halfHeight: Float?
    public let resourceID: String?
    public let center: EditorSceneManifestVector3

    public init(_ shape: ColliderShape) {
        switch shape {
        case let .box(halfExtents, center):
            self.kind = "box"
            self.halfExtents = EditorSceneManifestVector3(halfExtents)
            self.radius = nil
            self.halfHeight = nil
            self.resourceID = nil
            self.center = EditorSceneManifestVector3(center)
        case let .sphere(radius, center):
            self.kind = "sphere"
            self.halfExtents = nil
            self.radius = radius
            self.halfHeight = nil
            self.resourceID = nil
            self.center = EditorSceneManifestVector3(center)
        case let .capsule(radius, halfHeight, center):
            self.kind = "capsule"
            self.halfExtents = nil
            self.radius = radius
            self.halfHeight = halfHeight
            self.resourceID = nil
            self.center = EditorSceneManifestVector3(center)
        case let .mesh(resourceID, center):
            self.kind = "mesh"
            self.halfExtents = nil
            self.radius = nil
            self.halfHeight = nil
            self.resourceID = resourceID
            self.center = EditorSceneManifestVector3(center)
        case let .convex(resourceID, center):
            self.kind = "convex"
            self.halfExtents = nil
            self.radius = nil
            self.halfHeight = nil
            self.resourceID = resourceID
            self.center = EditorSceneManifestVector3(center)
        }
    }

    var shape: ColliderShape {
        switch kind {
        case "box":
            return .box(halfExtents: halfExtents?.simdValue ?? SIMD3<Float>(0.5, 0.5, 0.5),
                        center: center.simdValue)
        case "sphere":
            return .sphere(radius: radius ?? 0.5, center: center.simdValue)
        case "capsule":
            return .capsule(radius: radius ?? 0.5,
                            halfHeight: halfHeight ?? 0.5,
                            center: center.simdValue)
        case "mesh":
            return .mesh(resourceID: resourceID, center: center.simdValue)
        case "convex":
            return .convex(resourceID: resourceID, center: center.simdValue)
        default:
            return .box(halfExtents: SIMD3<Float>(0.5, 0.5, 0.5), center: center.simdValue)
        }
    }
}

public struct EditorSceneManifestCollider: Codable, Sendable, Equatable {
    public let shape: EditorSceneManifestColliderShape
    public let isTrigger: Bool
    public let layerID: UInt16
    public let layerMask: UInt16
    public let material: EditorSceneManifestPhysicsMaterial

    public init(_ component: Collider) {
        self.shape = EditorSceneManifestColliderShape(component.shape)
        self.isTrigger = component.isTrigger
        self.layerID = component.layerID
        self.layerMask = component.layerMask
        self.material = EditorSceneManifestPhysicsMaterial(component.material)
    }

    var component: Collider {
        Collider(shape: shape.shape,
                 isTrigger: isTrigger,
                 layerID: layerID,
                 layerMask: layerMask,
                 material: material.material)
    }
}

public struct EditorSceneManifestConstraint: Codable, Sendable, Equatable {
    public let constraintType: String
    public let entityA: UInt64
    public let entityB: UInt64
    public let pivotA: EditorSceneManifestVector3
    public let pivotB: EditorSceneManifestVector3
    public let axisA: EditorSceneManifestVector3
    public let axisB: EditorSceneManifestVector3
    public let minLimit: Float
    public let maxLimit: Float
    public let isEnabled: Bool

    public init(_ component: Constraint) {
        self.constraintType = component.constraintType.rawValue
        self.entityA = component.entityA.rawValue
        self.entityB = component.entityB.rawValue
        self.pivotA = EditorSceneManifestVector3(component.pivotA)
        self.pivotB = EditorSceneManifestVector3(component.pivotB)
        self.axisA = EditorSceneManifestVector3(component.axisA)
        self.axisB = EditorSceneManifestVector3(component.axisB)
        self.minLimit = component.minLimit
        self.maxLimit = component.maxLimit
        self.isEnabled = component.isEnabled
    }

    func component(idMap: [UInt64: EntityID]) -> Constraint? {
        guard let mappedA = idMap[entityA],
              let mappedB = idMap[entityB]
        else { return nil }
        return Constraint(constraintType: ConstraintType(rawValue: constraintType) ?? .distance,
                          entityA: mappedA,
                          entityB: mappedB,
                          pivotA: pivotA.simdValue,
                          pivotB: pivotB.simdValue,
                          axisA: axisA.simdValue,
                          axisB: axisB.simdValue,
                          minLimit: minLimit,
                          maxLimit: maxLimit,
                          isEnabled: isEnabled)
    }
}

public struct EditorSceneManifestScriptBinding: Codable, Sendable, Equatable {
    public let script: UInt64
    public let isEnabled: Bool
    public let parametersJSON: String

    public init(_ binding: ScriptBinding) {
        self.script = binding.script.rawValue
        self.isEnabled = binding.isEnabled
        self.parametersJSON = binding.parametersJSON
    }

    var binding: ScriptBinding {
        ScriptBinding(ScriptHandle(rawValue: script),
                      isEnabled: isEnabled,
                      parametersJSON: parametersJSON)
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

public struct EditorSceneManifestAudioSource: Codable, Sendable, Equatable {
    public let clipName: String
    public let volume: Float
    public let pitch: Float
    public let loop: Bool
    public let playOnAwake: Bool
    public let spatialBlend: Float

    public init(_ component: AudioSource) {
        self.clipName = component.clipName
        self.volume = component.volume
        self.pitch = component.pitch
        self.loop = component.loop
        self.playOnAwake = component.playOnAwake
        self.spatialBlend = component.spatialBlend
    }

    var component: AudioSource {
        AudioSource(clipName: clipName, volume: volume, pitch: pitch,
                    loop: loop, playOnAwake: playOnAwake, spatialBlend: spatialBlend)
    }
}

public struct EditorSceneManifestAnimationPlayer: Codable, Sendable, Equatable {
    public let clipName: String?
    public let speed: Float
    public let loop: Bool
    public let isPlaying: Bool
    public let time: Double

    public init(_ component: AnimationPlayer) {
        self.clipName = component.clipName
        self.speed = component.speed
        self.loop = component.loop
        self.isPlaying = component.isPlaying
        self.time = component.time
    }

    var component: AnimationPlayer {
        AnimationPlayer(clipName: clipName, speed: speed, loop: loop,
                        isPlaying: isPlaying, time: time)
    }
}

public struct EditorInspectorSection {
    public let id: String
    public let title: String
    public let fields: [EditorInspectorField]

    public init(id: String, title: String, fields: [EditorInspectorField]) {
        self.id = id
        self.title = title
        self.fields = fields
    }
}

public struct EditorInspectorField {
    public let id: String
    public let label: String
    public let value: EditorInspectorFieldValue

    public init(id: String, label: String, value: EditorInspectorFieldValue) {
        self.id = id
        self.label = label
        self.value = value
    }
}

public enum EditorInspectorFieldValue {
    case readOnly(String)
    case text(Binding<String>)
    case bool(Binding<Bool>)
    case number(Binding<Float>)
    case constrainedNumber(Binding<Float>, min: Float?, max: Float?, step: Float?, showsStepper: Bool)
    case vector3(x: Binding<Float>, y: Binding<Float>, z: Binding<Float>)
    case color(Binding<Color>)
    case json(Binding<String>, minHeight: Float)
    case lightType(Binding<LightType>)
    case rigidBodyMotion(Binding<RigidBodyMotionType>)
    case colliderShapeKind(Binding<ColliderShapeKind>)
}

/// 涓荤嚎绋嬬害瀹氱殑缂栬緫鍣ㄥ満鏅€傞厤灞傘€傚簳灞傛暟鎹潵鑷?Swift `SceneRuntime`锛?
/// 闈㈡澘鍙鍙栬繖閲屽鍑虹殑鏍戜笌灞炴€?schema锛屼笉鍐嶄緷璧?stub 鍒楄〃銆?
public final class EditorSceneAdapter: @unchecked Sendable {
    var scene = SceneRuntime()
    let transactionExecutor = TransactionExecutor()
    private var initialSelectionID: UInt64?
    private var initialExpandedIDs: Set<UInt64> = []
    let animationRuntime = AnimationRuntime()

    public var onRevisionChanged: ((UInt64) -> Void)?

    public init() {
        resetToPreviewScene(notify: false)
    }

    public func resetToPreviewScene() {
        resetToPreviewScene(notify: true)
    }

    private func resetToPreviewScene(notify: Bool) {
        scene = SceneRuntime()
        scene.bootstrapEditorPreviewScene()
        let defaults = scene.resource(SceneBootstrapDefaultsResource.self)
        initialSelectionID = defaults?.defaultSelection?.rawValue
        initialExpandedIDs = Set(defaults?.defaultExpanded.map(\ .rawValue) ?? [])
        if notify {
            notifyRevisionChanged()
        }
    }

    public var revision: UInt64 {
        scene.snapshot.revision
    }

    public var entityCount: Int {
        scene.snapshot.entityCount
    }

    public var defaultSelectionID: UInt64? {
        initialSelectionID
    }

    public var defaultExpandedEntityIDs: Set<UInt64> {
        initialExpandedIDs
    }

    public var roots: [EditorSceneNode] {
        scene.roots().map(buildNode)
    }

    public func manifest(selectedEntityID: UInt64? = nil) -> EditorSceneManifest {
        let selectedEntity = entity(from: selectedEntityID)
        let restoredSelection = selectedEntity.flatMap { scene.contains($0) ? $0.rawValue : nil }
        let physicsSettings = scene.resource(PhysicsSettingsResource.self)
            .map(EditorSceneManifestPhysicsSettings.init)
        let sceneKind = scene.resource(SceneKindComponent.self)?.value
        let assetCount = AssetRegistry.shared.entriesSnapshot().count
        let timestamp = ISO8601DateFormatter().string(from: Date())
        return EditorSceneManifest(revision: revision,
                                   entityCount: entityCount,
                                   selectedEntityID: restoredSelection,
                                   sceneKind: sceneKind,
                                   physicsSettings: physicsSettings,
                                   projectAssetCount: assetCount > 0 ? assetCount : nil,
                                   lastModifiedAt: timestamp,
                                   roots: scene.roots().map(manifestNode))
    }

    @discardableResult
    public func load(manifest: EditorSceneManifest, notify: Bool = true) -> EditorSceneManifestLoadResult {
        var restoredScene = SceneRuntime()
        var idMap: [UInt64: EntityID] = [:]

        @discardableResult
        func restoreNode(_ node: EditorSceneManifestNode) -> EntityID {
            let entity = restoredScene.createEntity()
            idMap[node.id] = entity
            _ = restoredScene.setComponent(SceneNameComponent(value: node.name), for: entity)
            _ = restoredScene.setComponent(SceneKindComponent(value: node.kind), for: entity)
            _ = restoredScene.setLocalTransform(node.localTransform?.localTransform ?? .identity,
                                                for: entity)
            if let asset = node.asset {
                _ = restoredScene.setComponent(asset.component, for: entity)
            }
            if let renderMesh = node.renderMesh {
                _ = restoredScene.setComponent(renderMesh.component, for: entity)
            }
            if let renderMaterial = node.renderMaterial {
                _ = restoredScene.setComponent(renderMaterial.component, for: entity)
            }
            if let camera = node.camera {
                _ = restoredScene.setComponent(camera.component, for: entity)
            }
            if let light = node.light {
                _ = restoredScene.setComponent(light.component, for: entity)
            }
            if let rigidBody = node.rigidBody {
                _ = restoredScene.setComponent(rigidBody.component, for: entity)
            }
            if let collider = node.collider {
                _ = restoredScene.setComponent(collider.component, for: entity)
            }
            if let script = node.script {
                _ = restoredScene.setComponent(script.component, for: entity)
            }
            if let audioSource = node.audioSource {
                _ = restoredScene.setComponent(audioSource.component, for: entity)
            }
            if let animationPlayer = node.animationPlayer {
                _ = restoredScene.setComponent(animationPlayer.component, for: entity)
            }
            for child in node.children {
                let childEntity = restoreNode(child)
                _ = restoredScene.setParent(entity, for: childEntity)
            }
            return entity
        }

        func restoreConstraints(_ node: EditorSceneManifestNode) {
            if let entity = idMap[node.id],
               let constraint = node.constraint?.component(idMap: idMap) {
                _ = restoredScene.setComponent(constraint, for: entity)
            }
            for child in node.children {
                restoreConstraints(child)
            }
        }

        for root in manifest.roots {
            restoreNode(root)
        }
        for root in manifest.roots {
            restoreConstraints(root)
        }
        if let physicsSettings = manifest.physicsSettings {
            restoredScene.setResource(physicsSettings.settings)
        }
        rebuildMeshColliderResources(in: &restoredScene)
        restoredScene.propagateTransforms()

        scene = restoredScene
        initialSelectionID = manifest.selectedEntityID.flatMap { idMap[$0]?.rawValue }
            ?? scene.roots().first?.rawValue
        initialExpandedIDs = Set(scene.roots().map(\.rawValue))
        if notify {
            notifyRevisionChanged()
        }
        return EditorSceneManifestLoadResult(entityCount: entityCount,
                                             selectedEntityID: initialSelectionID)
    }

    @discardableResult
    public func moveEntity(_ entityID: UInt64,
                           to parentID: UInt64?,
                           at index: Int) -> TransactionApplyResult? {
        applySceneTransaction(intentVerb: "scene.move_entity",
                              summary: "Move entity in hierarchy",
                              targetRawIDs: [entityID],
                              mutations: [.moveEntity(entityID: entityID,
                                                      parentID: parentID,
                                                      index: index)])
    }

    public func entitySummary(id rawID: UInt64?) -> EditorSceneEntitySummary? {
        guard let entity = entity(from: rawID), scene.contains(entity) else {
            return nil
        }
        return EditorSceneEntitySummary(
            id: entity.rawValue,
            name: displayName(for: entity),
            kind: displayKind(for: entity)
        )
    }

    public func inspectorSections(for rawID: UInt64?) -> [EditorInspectorSection] {
        guard let entity = entity(from: rawID), scene.contains(entity) else {
            return []
        }

        var sections: [EditorInspectorSection] = [
            generalSection(for: entity),
            hierarchySection(for: entity),
        ]

        if let transformSection = transformSection(for: entity) {
            sections.append(transformSection)
        }
        if let rigidBodySection = rigidBodySection(for: entity) {
            sections.append(rigidBodySection)
        }
        if let colliderSection = colliderSection(for: entity) {
            sections.append(colliderSection)
        }
        if let constraintSection = constraintSection(for: entity) {
            sections.append(constraintSection)
        }
        if let lightSection = lightSection(for: entity) {
            sections.append(lightSection)
        }
        if let scriptSection = scriptSection(for: entity) {
            sections.append(scriptSection)
        }
        if let animationPlayerSection = animationPlayerSection(for: entity) {
            sections.append(animationPlayerSection)
        }
        if let audioSourceSection = audioSourceSection(for: entity) {
            sections.append(audioSourceSection)
        }
        if let renderMeshSection = renderMeshSection(for: entity) {
            sections.append(renderMeshSection)
        }
        if let renderMaterialSection = renderMaterialSection(for: entity) {
            sections.append(renderMaterialSection)
        }

        return sections
    }

    private func buildNode(_ entity: EntityID) -> EditorSceneNode {
        EditorSceneNode(
            id: entity.rawValue,
            name: displayName(for: entity),
            kind: displayKind(for: entity),
            children: scene.children(of: entity).map(buildNode)
        )
    }

    private func manifestNode(_ entity: EntityID) -> EditorSceneManifestNode {
        EditorSceneManifestNode(
            id: entity.rawValue,
            name: displayName(for: entity),
            kind: displayKind(for: entity),
            localTransform: scene.localTransform(for: entity).map { EditorSceneManifestMatrix($0.matrix) },
            asset: scene.component(AssetReferenceComponent.self, for: entity)
                .map(EditorSceneManifestAssetReference.init),
            renderMesh: scene.component(RenderMeshComponent.self, for: entity)
                .map(EditorSceneManifestRenderMesh.init),
            renderMaterial: scene.component(RenderMaterialComponent.self, for: entity)
                .map(EditorSceneManifestRenderMaterial.init),
            camera: scene.component(CameraComponent.self, for: entity)
                .map(EditorSceneManifestCamera.init),
            light: scene.component(LightComponent.self, for: entity)
                .map(EditorSceneManifestLight.init),
            rigidBody: scene.component(RigidBody.self, for: entity)
                .map(EditorSceneManifestRigidBody.init),
            collider: scene.component(Collider.self, for: entity)
                .map(EditorSceneManifestCollider.init),
            constraint: scene.component(Constraint.self, for: entity)
                .map(EditorSceneManifestConstraint.init),
            script: scene.component(ScriptComponent.self, for: entity)
                .map(EditorSceneManifestScript.init),
            audioSource: scene.component(AudioSource.self, for: entity)
                .map(EditorSceneManifestAudioSource.init),
            animationPlayer: scene.component(AnimationPlayer.self, for: entity)
                .map(EditorSceneManifestAnimationPlayer.init),
            children: scene.children(of: entity).map(manifestNode)
        )
    }

    private func rebuildMeshColliderResources(in runtime: inout SceneRuntime) {
        var boundsResource = runtime.resource(MeshColliderBoundsResource.self) ?? MeshColliderBoundsResource()
        var geometryResource = runtime.resource(MeshColliderGeometryResource.self) ?? MeshColliderGeometryResource()
        var changedBounds = false
        var changedGeometry = false

        for entity in runtime.entities() {
            guard let asset = runtime.component(AssetReferenceComponent.self, for: entity),
                  let collider = runtime.component(Collider.self, for: entity),
                  case let .mesh(resourceID, _) = collider.shape,
                  let mesh = AssetRegistry.shared.meshAsset(for: asset.meshIndex) else {
                continue
            }

            let resolvedResourceID = resourceID ?? meshColliderResourceID(for: asset.meshIndex)
            let bounds = SpatialAABB(min: mesh.localBounds.min, max: mesh.localBounds.max)
            boundsResource.boundsByResourceID[resolvedResourceID] = bounds
            changedBounds = true

            if mesh.triangleCount > 0 {
                geometryResource.geometryByResourceID[resolvedResourceID] = MeshColliderGeometry(
                    positions: (0..<mesh.vertexCount).compactMap { mesh.position(at: $0) },
                    triangleIndices: mesh.indices,
                    localBounds: bounds
                )
                changedGeometry = true
            }
        }

        if changedBounds {
            runtime.setResource(boundsResource)
        }
        if changedGeometry {
            runtime.setResource(geometryResource)
        }
    }

    private func generalSection(for entity: EntityID) -> EditorInspectorSection {
        EditorInspectorSection(
            id: "general",
            title: L("General"),
            fields: [
                EditorInspectorField(
                    id: "name",
                    label: L("Name"),
                    value: .text(nameBinding(for: entity))
                ),
                EditorInspectorField(
                    id: "kind",
                    label: L("Kind"),
                    value: .readOnly(displayKind(for: entity))
                ),
                EditorInspectorField(
                    id: "entity-id",
                    label: L("Entity ID"),
                    value: .readOnly(String(entity.rawValue))
                ),
            ]
        )
    }

    private func hierarchySection(for entity: EntityID) -> EditorInspectorSection {
        let parentLabel: String
        if let parent = scene.parent(of: entity) {
            parentLabel = displayName(for: parent)
        } else {
            parentLabel = L("Root")
        }

        return EditorInspectorSection(
            id: "hierarchy",
            title: L("Hierarchy"),
            fields: [
                EditorInspectorField(
                    id: "parent",
                    label: L("Parent"),
                    value: .readOnly(parentLabel)
                ),
                EditorInspectorField(
                    id: "children",
                    label: L("Children"),
                    value: .readOnly(String(scene.children(of: entity).count))
                ),
            ]
        )
    }

    private func transformSection(for entity: EntityID) -> EditorInspectorSection? {
        let local = scene.localTransform(for: entity)
        let world = scene.worldTransform(for: entity)
        guard local != nil || world != nil else { return nil }

        var fields: [EditorInspectorField] = []
        if local != nil {
            fields.append(
                EditorInspectorField(
                    id: "local-position",
                    label: L("Local Position"),
                    value: .vector3(x: localPositionBinding(for: entity, axis: \.x),
                                    y: localPositionBinding(for: entity, axis: \.y),
                                    z: localPositionBinding(for: entity, axis: \.z))
                )
            )
            fields.append(
                EditorInspectorField(
                    id: "local-rotation",
                    label: L("Rotation"),
                    value: .vector3(x: localRotationBinding(for: entity, axis: \.x),
                                    y: localRotationBinding(for: entity, axis: \.y),
                                    z: localRotationBinding(for: entity, axis: \.z))
                )
            )
            fields.append(
                EditorInspectorField(
                    id: "local-scale",
                    label: L("Scale"),
                    value: .vector3(x: localScaleBinding(for: entity, axis: \.x),
                                    y: localScaleBinding(for: entity, axis: \.y),
                                    z: localScaleBinding(for: entity, axis: \.z))
                )
            )
        }
        if world != nil {
            let displayed = entityWorldPosition(entity.rawValue) ?? world!.translation
            fields.append(
                EditorInspectorField(
                    id: "world-position",
                    label: L("World Position"),
                    value: .readOnly(format(displayed))
                )
            )
        }

        return EditorInspectorSection(id: "transform", title: L("Transform"), fields: fields)
    }

    private func rigidBodySection(for entity: EntityID) -> EditorInspectorSection? {
        guard let body = scene.component(RigidBody.self, for: entity) else {
            return nil
        }

        return EditorInspectorSection(
            id: "rigid-body",
            title: L("Rigid Body"),
            fields: [
                EditorInspectorField(
                    id: "motion",
                    label: L("Motion"),
                    value: .rigidBodyMotion(rigidBodyMotionBinding(for: entity))
                ),
                EditorInspectorField(
                    id: "mass",
                    label: L("Mass"),
                    value: .constrainedNumber(rigidBodyMassBinding(for: entity),
                                              min: 0,
                                              max: nil,
                                              step: 0.5,
                                              showsStepper: true)
                ),
                EditorInspectorField(
                    id: "gravity-scale",
                    label: L("Gravity"),
                    value: .constrainedNumber(rigidBodyGravityScaleBinding(for: entity),
                                              min: nil,
                                              max: nil,
                                              step: 0.1,
                                              showsStepper: true)
                ),
                EditorInspectorField(
                    id: "allow-sleep",
                    label: L("Allow Sleep"),
                    value: .bool(rigidBodyAllowSleepBinding(for: entity))
                ),
                EditorInspectorField(
                    id: "sleeping",
                    label: L("Sleeping"),
                    value: .readOnly(body.isSleeping ? L("Yes") : L("No"))
                ),
            ]
        )
    }

    private func colliderSection(for entity: EntityID) -> EditorInspectorSection? {
        guard let collider = scene.component(Collider.self, for: entity) else {
            return nil
        }

        var fields: [EditorInspectorField] = [
            EditorInspectorField(
                id: "shape-kind",
                label: L("Shape"),
                value: .colliderShapeKind(colliderShapeKindBinding(for: entity))
            ),
        ]

        switch collider.shape {
        case .box:
            fields.append(
                EditorInspectorField(
                    id: "shape-box-extents",
                    label: L("Half Extents"),
                    value: .vector3(x: colliderBoxHalfExtentsBinding(for: entity, axis: \.x),
                                    y: colliderBoxHalfExtentsBinding(for: entity, axis: \.y),
                                    z: colliderBoxHalfExtentsBinding(for: entity, axis: \.z))
                )
            )
        case .sphere:
            fields.append(
                EditorInspectorField(
                    id: "shape-sphere-radius",
                    label: L("Radius"),
                    value: .constrainedNumber(colliderSphereRadiusBinding(for: entity),
                                              min: 0.01, max: nil, step: 0.1, showsStepper: true)
                )
            )
        case .capsule:
            fields.append(
                EditorInspectorField(
                    id: "shape-capsule-radius",
                    label: L("Radius"),
                    value: .constrainedNumber(colliderCapsuleRadiusBinding(for: entity),
                                              min: 0.01, max: nil, step: 0.1, showsStepper: true)
                )
            )
            fields.append(
                EditorInspectorField(
                    id: "shape-capsule-half-height",
                    label: L("Half Height"),
                    value: .constrainedNumber(colliderCapsuleHalfHeightBinding(for: entity),
                                              min: 0.01, max: nil, step: 0.1, showsStepper: true)
                )
            )
        case .mesh:
            let resourceLabel = collider.shape.resourceID ?? L("(auto)")
            fields.append(
                EditorInspectorField(
                    id: "shape-mesh-resource",
                    label: L("Resource"),
                    value: .readOnly(resourceLabel)
                )
            )
        case .convex:
            let resourceLabel = collider.shape.resourceID ?? L("(auto)")
            fields.append(
                EditorInspectorField(
                    id: "shape-convex-resource",
                    label: L("Resource"),
                    value: .readOnly(resourceLabel)
                )
            )
        }

        fields.append(
            EditorInspectorField(
                id: "trigger",
                label: L("Trigger"),
                value: .bool(colliderTriggerBinding(for: entity))
            )
        )

        fields.append(
            EditorInspectorField(
                id: "material-friction",
                label: L("Friction"),
                value: .constrainedNumber(colliderFrictionBinding(for: entity),
                                          min: 0, max: nil, step: 0.1, showsStepper: true)
            )
        )
        fields.append(
            EditorInspectorField(
                id: "material-restitution",
                label: L("Restitution"),
                value: .constrainedNumber(colliderRestitutionBinding(for: entity),
                                          min: 0, max: 1, step: 0.05, showsStepper: true)
            )
        )
        fields.append(
            EditorInspectorField(
                id: "material-density",
                label: L("Density"),
                value: .constrainedNumber(colliderDensityBinding(for: entity),
                                          min: 0, max: nil, step: 0.1, showsStepper: true)
            )
        )

        fields.append(
            EditorInspectorField(
                id: "layer",
                label: L("Layer"),
                value: .constrainedNumber(colliderLayerBinding(for: entity),
                                          min: 0, max: 65535, step: 1, showsStepper: true)
            )
        )

        return EditorInspectorSection(
            id: "collider",
            title: L("Collider"),
            fields: fields
        )
    }

    private func constraintSection(for entity: EntityID) -> EditorInspectorSection? {
        guard let constraint = scene.component(Constraint.self, for: entity) else {
            return nil
        }

        return EditorInspectorSection(
            id: "constraint",
            title: L("Constraint"),
            fields: [
                EditorInspectorField(
                    id: "type",
                    label: L("Type"),
                    value: .readOnly(constraint.constraintType.rawValue)
                ),
                EditorInspectorField(
                    id: "entity-a",
                    label: L("Entity A"),
                    value: .readOnly(displayName(for: constraint.entityA))
                ),
                EditorInspectorField(
                    id: "entity-b",
                    label: L("Entity B"),
                    value: .readOnly(displayName(for: constraint.entityB))
                ),
                EditorInspectorField(
                    id: "limits",
                    label: L("Limits"),
                    value: .readOnly("\(format(constraint.minLimit)) ... \(format(constraint.maxLimit))")
                ),
                EditorInspectorField(
                    id: "enabled",
                    label: L("Enabled"),
                    value: .bool(constraintEnabledBinding(for: entity))
                ),
            ]
        )
    }

    private func lightSection(for entity: EntityID) -> EditorInspectorSection? {
        guard let light = scene.component(LightComponent.self, for: entity) else {
            return nil
        }

        var fields: [EditorInspectorField] = [
            EditorInspectorField(
                id: "type",
                label: L("Type"),
                value: .lightType(lightTypeBinding(for: entity))
            ),
            EditorInspectorField(
                id: "color",
                label: L("Color"),
                value: .color(lightColorBinding(for: entity))
            )
        ]

        switch light.type {
        case .directional:
            fields.append(
                EditorInspectorField(
                    id: "intensity",
                    label: L("Intensity"),
                    value: .number(lightIntensityBinding(for: entity))
                )
            )
        case .point:
            fields.append(
                EditorInspectorField(
                    id: "intensity",
                    label: L("Intensity"),
                    value: .constrainedNumber(lightIntensityBinding(for: entity),
                                              min: 0,
                                              max: nil,
                                              step: 0.1,
                                              showsStepper: true)
                )
            )
            fields.append(
                EditorInspectorField(
                    id: "range",
                    label: L("Range"),
                    value: .constrainedNumber(lightRangeBinding(for: entity),
                                              min: 0,
                                              max: nil,
                                              step: 0.1,
                                              showsStepper: true)
                )
            )
        case .spot:
            fields.append(
                EditorInspectorField(
                    id: "intensity",
                    label: L("Intensity"),
                    value: .constrainedNumber(lightIntensityBinding(for: entity),
                                              min: 0,
                                              max: nil,
                                              step: 0.1,
                                              showsStepper: true)
                )
            )
            fields.append(
                EditorInspectorField(
                    id: "range",
                    label: L("Range"),
                    value: .constrainedNumber(lightRangeBinding(for: entity),
                                              min: 0,
                                              max: nil,
                                              step: 0.1,
                                              showsStepper: true)
                )
            )
            fields.append(
                EditorInspectorField(
                    id: "spot-inner-angle",
                    label: L("Inner Angle"),
                    value: .constrainedNumber(lightSpotInnerAngleBinding(for: entity),
                                              min: 0,
                                              max: 179,
                                              step: 1,
                                              showsStepper: true)
                )
            )
            fields.append(
                EditorInspectorField(
                    id: "spot-outer-angle",
                    label: L("Outer Angle"),
                    value: .constrainedNumber(lightSpotOuterAngleBinding(for: entity),
                                              min: 1,
                                              max: 179,
                                              step: 1,
                                              showsStepper: true)
                )
            )
            fields.append(
                EditorInspectorField(
                    id: "spot-cone-hint",
                    label: L("Cone"),
                    value: .readOnly("\(format(light.spotInnerAngleDegrees))掳 -> \(format(light.spotOuterAngleDegrees))掳")
                )
            )
        }

        return EditorInspectorSection(
            id: "light",
            title: L("Light"),
            fields: fields
        )
    }

    private func scriptSection(for entity: EntityID) -> EditorInspectorSection? {
        guard let component = scene.component(ScriptComponent.self, for: entity) else {
            return nil
        }

        var fields: [EditorInspectorField] = []
        for (index, binding) in component.bindings.enumerated() {
            let ordinal = index + 1
            fields.append(
                EditorInspectorField(
                    id: "script-\(index)-enabled",
                    label: String(format: L("Script %d"), ordinal),
                    value: .bool(scriptEnabledBinding(for: entity, index: index))
                )
            )
            fields.append(
                EditorInspectorField(
                    id: "script-\(index)-handle",
                    label: L("Handle"),
                    value: .readOnly("#\(binding.script.rawValue)")
                )
            )
            fields.append(
                EditorInspectorField(
                    id: "script-\(index)-parameters",
                    label: L("Parameters"),
                    value: .json(scriptParametersBinding(for: entity, index: index), minHeight: 96)
                )
            )
        }

        if fields.isEmpty {
            fields.append(
                EditorInspectorField(
                    id: "script-empty",
                    label: L("Bindings"),
                    value: .readOnly(L("No scripts"))
                )
            )
        }

        return EditorInspectorSection(id: "scripts", title: L("Scripts"), fields: fields)
    }

    private func animationPlayerSection(for entity: EntityID) -> EditorInspectorSection? {
        guard scene.hasComponent(AnimationPlayer.self, for: entity) else { return nil }

        return EditorInspectorSection(
            id: "animation-player",
            title: L("Animation Player"),
            fields: [
                EditorInspectorField(
                    id: "anim-clip",
                    label: L("Clip"),
                    value: .text(animationClipNameBinding(for: entity))
                ),
                EditorInspectorField(
                    id: "anim-speed",
                    label: L("Speed"),
                    value: .constrainedNumber(animationSpeedBinding(for: entity),
                                              min: 0, max: 10, step: 0.1, showsStepper: true)
                ),
                EditorInspectorField(
                    id: "anim-loop",
                    label: L("Loop"),
                    value: .bool(animationLoopBinding(for: entity))
                ),
                EditorInspectorField(
                    id: "anim-playing",
                    label: L("Playing"),
                    value: .bool(animationIsPlayingBinding(for: entity))
                ),
            ]
        )
    }

    private func animationClipNameBinding(for entity: EntityID) -> Binding<String> {
        Binding(
            get: { [self] in
                scene.component(AnimationPlayer.self, for: entity)?.clipName ?? ""
            },
            set: { [self] next in
                guard let player = scene.component(AnimationPlayer.self, for: entity) else { return }
                let clipName: String? = next.isEmpty ? nil : next
                guard player.clipName != clipName else { return }
                _ = applySceneTransaction(intentVerb: "scene.set_animation_clip",
                                          summary: "Update animation clip",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setAnimationPlayer(entityID: entity.rawValue,
                                                                          clipName: clipName,
                                                                          speed: player.speed,
                                                                          loop: player.loop,
                                                                          isPlaying: player.isPlaying)])
            }
        )
    }

    private func animationSpeedBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(AnimationPlayer.self, for: entity)?.speed ?? 1
            },
            set: { [self] next in
                guard let player = scene.component(AnimationPlayer.self, for: entity),
                      player.speed != next else { return }
                _ = applySceneTransaction(intentVerb: "scene.set_animation_speed",
                                          summary: "Update animation speed",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setAnimationPlayer(entityID: entity.rawValue,
                                                                          clipName: player.clipName,
                                                                          speed: next,
                                                                          loop: player.loop,
                                                                          isPlaying: player.isPlaying)])
            }
        )
    }

    private func animationLoopBinding(for entity: EntityID) -> Binding<Bool> {
        Binding(
            get: { [self] in
                scene.component(AnimationPlayer.self, for: entity)?.loop ?? true
            },
            set: { [self] next in
                guard let player = scene.component(AnimationPlayer.self, for: entity),
                      player.loop != next else { return }
                _ = applySceneTransaction(intentVerb: "scene.set_animation_loop",
                                          summary: "Update animation loop",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setAnimationPlayer(entityID: entity.rawValue,
                                                                          clipName: player.clipName,
                                                                          speed: player.speed,
                                                                          loop: next,
                                                                          isPlaying: player.isPlaying)])
            }
        )
    }

    private func animationIsPlayingBinding(for entity: EntityID) -> Binding<Bool> {
        Binding(
            get: { [self] in
                scene.component(AnimationPlayer.self, for: entity)?.isPlaying ?? false
            },
            set: { [self] next in
                guard let player = scene.component(AnimationPlayer.self, for: entity),
                      player.isPlaying != next else { return }
                _ = applySceneTransaction(intentVerb: "scene.set_animation_playing",
                                          summary: "Update animation playing state",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setAnimationPlayer(entityID: entity.rawValue,
                                                                          clipName: player.clipName,
                                                                          speed: player.speed,
                                                                          loop: player.loop,
                                                                          isPlaying: next)])
            }
        )
    }

    private func audioSourceSection(for entity: EntityID) -> EditorInspectorSection? {
        guard scene.hasComponent(AudioSource.self, for: entity) else { return nil }
        return EditorInspectorSection(
            id: "audio-source",
            title: L("Audio Source"),
            fields: [
                EditorInspectorField(
                    id: "audio-clip",
                    label: L("Clip"),
                    value: .text(audioClipNameBinding(for: entity))
                ),
                EditorInspectorField(
                    id: "audio-volume",
                    label: L("Volume"),
                    value: .constrainedNumber(audioVolumeBinding(for: entity),
                                              min: 0, max: 1, step: 0.05, showsStepper: true)
                ),
                EditorInspectorField(
                    id: "audio-pitch",
                    label: L("Pitch"),
                    value: .constrainedNumber(audioPitchBinding(for: entity),
                                              min: 0.1, max: 3, step: 0.1, showsStepper: true)
                ),
                EditorInspectorField(
                    id: "audio-loop",
                    label: L("Loop"),
                    value: .bool(audioLoopBinding(for: entity))
                ),
                EditorInspectorField(
                    id: "audio-play-on-awake",
                    label: L("Play on Awake"),
                    value: .bool(audioPlayOnAwakeBinding(for: entity))
                ),
                EditorInspectorField(
                    id: "audio-spatial-blend",
                    label: L("Spatial Blend"),
                    value: .constrainedNumber(audioSpatialBlendBinding(for: entity),
                                              min: 0, max: 1, step: 0.1, showsStepper: true)
                ),
            ]
        )
    }

    private func audioClipNameBinding(for entity: EntityID) -> Binding<String> {
        Binding(
            get: { [self] in
                scene.component(AudioSource.self, for: entity)?.clipName ?? ""
            },
            set: { [self] next in
                guard var source = scene.component(AudioSource.self, for: entity),
                      source.clipName != next else { return }
                source.clipName = next
                _ = applySceneTransaction(intentVerb: "scene.set_audio_clip",
                                          summary: "Update audio clip",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setAudioSource(entityID: entity.rawValue, source: source)])
            }
        )
    }

    private func audioVolumeBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(AudioSource.self, for: entity)?.volume ?? 1
            },
            set: { [self] next in
                guard var source = scene.component(AudioSource.self, for: entity),
                      source.volume != next else { return }
                source.volume = next
                _ = applySceneTransaction(intentVerb: "scene.set_audio_volume",
                                          summary: "Update audio volume",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setAudioSource(entityID: entity.rawValue, source: source)])
            }
        )
    }

    private func audioPitchBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(AudioSource.self, for: entity)?.pitch ?? 1
            },
            set: { [self] next in
                guard var source = scene.component(AudioSource.self, for: entity),
                      source.pitch != next else { return }
                source.pitch = next
                _ = applySceneTransaction(intentVerb: "scene.set_audio_pitch",
                                          summary: "Update audio pitch",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setAudioSource(entityID: entity.rawValue, source: source)])
            }
        )
    }

    private func audioLoopBinding(for entity: EntityID) -> Binding<Bool> {
        Binding(
            get: { [self] in
                scene.component(AudioSource.self, for: entity)?.loop ?? false
            },
            set: { [self] next in
                guard var source = scene.component(AudioSource.self, for: entity),
                      source.loop != next else { return }
                source.loop = next
                _ = applySceneTransaction(intentVerb: "scene.set_audio_loop",
                                          summary: "Update audio loop",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setAudioSource(entityID: entity.rawValue, source: source)])
            }
        )
    }

    private func audioPlayOnAwakeBinding(for entity: EntityID) -> Binding<Bool> {
        Binding(
            get: { [self] in
                scene.component(AudioSource.self, for: entity)?.playOnAwake ?? true
            },
            set: { [self] next in
                guard var source = scene.component(AudioSource.self, for: entity),
                      source.playOnAwake != next else { return }
                source.playOnAwake = next
                _ = applySceneTransaction(intentVerb: "scene.set_audio_play_on_awake",
                                          summary: "Update audio play on awake",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setAudioSource(entityID: entity.rawValue, source: source)])
            }
        )
    }

    private func audioSpatialBlendBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(AudioSource.self, for: entity)?.spatialBlend ?? 1
            },
            set: { [self] next in
                guard var source = scene.component(AudioSource.self, for: entity),
                      source.spatialBlend != next else { return }
                source.spatialBlend = next
                _ = applySceneTransaction(intentVerb: "scene.set_audio_spatial_blend",
                                          summary: "Update audio spatial blend",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setAudioSource(entityID: entity.rawValue, source: source)])
            }
        )
    }

    private func lightTypeBinding(for entity: EntityID) -> Binding<LightType> {
        Binding(
            get: { [self] in
                scene.component(LightComponent.self, for: entity)?.type ?? .directional
            },
            set: { [self] next in
                guard scene.component(LightComponent.self, for: entity)?.type != next else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_light_type",
                                          summary: "Update light type",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setLightType(entityID: entity.rawValue, type: next)])
            }
        )
    }

    private func nameBinding(for entity: EntityID) -> Binding<String> {
        Binding(
            get: { [self] in
                scene.component(SceneNameComponent.self, for: entity)?.value ?? fallbackName(for: entity)
            },
            set: { [self] next in
                let trimmed = next.trimmingCharacters(in: .whitespacesAndNewlines)
                let value = trimmed.isEmpty ? fallbackName(for: entity) : trimmed
                guard scene.component(SceneNameComponent.self, for: entity)?.value != value else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_name",
                                          summary: "Rename entity",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setSceneName(entityID: entity.rawValue, value: value)])
            }
        )
    }

    private func rigidBodyAllowSleepBinding(for entity: EntityID) -> Binding<Bool> {
        Binding(
            get: { [self] in
                scene.component(RigidBody.self, for: entity)?.allowSleep ?? false
            },
            set: { [self] next in
                guard scene.component(RigidBody.self, for: entity)?.allowSleep != next else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_rigidbody_allow_sleep",
                                          summary: "Update rigid body sleep flag",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setRigidBodyAllowSleep(entityID: entity.rawValue, value: next)])
            }
        )
    }

    private func rigidBodyMotionBinding(for entity: EntityID) -> Binding<RigidBodyMotionType> {
        Binding(
            get: { [self] in
                scene.component(RigidBody.self, for: entity)?.motionType ?? .dynamic
            },
            set: { [self] next in
                guard scene.component(RigidBody.self, for: entity)?.motionType != next else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_rigidbody_motion",
                                          summary: "Update rigid body motion type",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setRigidBodyMotionType(entityID: entity.rawValue, value: next)])
            }
        )
    }

    private func rigidBodyMassBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(RigidBody.self, for: entity)?.mass ?? 0
            },
            set: { [self] next in
                let clamped = max(0, next)
                guard scene.component(RigidBody.self, for: entity)?.mass != clamped else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_rigidbody_mass",
                                          summary: "Update rigid body mass",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setRigidBodyMass(entityID: entity.rawValue, value: clamped)])
            }
        )
    }

    private func rigidBodyGravityScaleBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(RigidBody.self, for: entity)?.gravityScale ?? 0
            },
            set: { [self] next in
                guard scene.component(RigidBody.self, for: entity)?.gravityScale != next else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_rigidbody_gravity_scale",
                                          summary: "Update rigid body gravity scale",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setRigidBodyGravityScale(entityID: entity.rawValue, value: next)])
            }
        )
    }

    private func colliderTriggerBinding(for entity: EntityID) -> Binding<Bool> {
        Binding(
            get: { [self] in
                scene.component(Collider.self, for: entity)?.isTrigger ?? false
            },
            set: { [self] next in
                guard scene.component(Collider.self, for: entity)?.isTrigger != next else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_collider_trigger",
                                          summary: "Update collider trigger flag",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setColliderTrigger(entityID: entity.rawValue, value: next)])
            }
        )
    }

    private func colliderShapeKindBinding(for entity: EntityID) -> Binding<ColliderShapeKind> {
        Binding(
            get: { [self] in
                scene.component(Collider.self, for: entity)?.shape.kind ?? .box
            },
            set: { [self] next in
                guard scene.component(Collider.self, for: entity)?.shape.kind != next else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_collider_shape_type",
                                          summary: "Update collider shape type",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setColliderShapeType(entityID: entity.rawValue, kind: next)])
            }
        )
    }

    private func colliderBoxHalfExtentsBinding(for entity: EntityID,
                                                axis: WritableKeyPath<SIMD3<Float>, Float>) -> Binding<Float> {
        Binding(
            get: { [self] in
                if let collider = scene.component(Collider.self, for: entity),
                   case let .box(he, _) = collider.shape {
                    return he[keyPath: axis]
                }
                return 0.5
            },
            set: { [self] next in
                guard let collider = scene.component(Collider.self, for: entity),
                      case let .box(he, _) = collider.shape,
                      he[keyPath: axis] != next else { return }
                var newHE = he
                newHE[keyPath: axis] = max(0.01, next)
                _ = applySceneTransaction(intentVerb: "scene.set_collider_box_extents",
                                          summary: "Update collider box extents",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setColliderShapeBoxHalfExtents(entityID: entity.rawValue,
                                                                                      halfExtents: newHE)])
            }
        )
    }

    private func colliderSphereRadiusBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                if let collider = scene.component(Collider.self, for: entity),
                   case let .sphere(r, _) = collider.shape {
                    return r
                }
                return 0.5
            },
            set: { [self] next in
                let clamped = max(0.01, next)
                guard let collider = scene.component(Collider.self, for: entity),
                      case let .sphere(r, _) = collider.shape,
                      r != clamped else { return }
                _ = applySceneTransaction(intentVerb: "scene.set_collider_sphere_radius",
                                          summary: "Update collider sphere radius",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setColliderShapeSphereRadius(entityID: entity.rawValue,
                                                                                    radius: clamped)])
            }
        )
    }

    private func colliderCapsuleRadiusBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                if let collider = scene.component(Collider.self, for: entity),
                   case let .capsule(r, _, _) = collider.shape {
                    return r
                }
                return 0.5
            },
            set: { [self] next in
                let clamped = max(0.01, next)
                guard let collider = scene.component(Collider.self, for: entity),
                      case let .capsule(r, _, _) = collider.shape,
                      r != clamped else { return }
                _ = applySceneTransaction(intentVerb: "scene.set_collider_capsule_radius",
                                          summary: "Update collider capsule radius",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setColliderShapeCapsuleRadius(entityID: entity.rawValue,
                                                                                     radius: clamped)])
            }
        )
    }

    private func colliderCapsuleHalfHeightBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                if let collider = scene.component(Collider.self, for: entity),
                   case let .capsule(_, hh, _) = collider.shape {
                    return hh
                }
                return 0.5
            },
            set: { [self] next in
                let clamped = max(0.01, next)
                guard let collider = scene.component(Collider.self, for: entity),
                      case let .capsule(_, hh, _) = collider.shape,
                      hh != clamped else { return }
                _ = applySceneTransaction(intentVerb: "scene.set_collider_capsule_half_height",
                                          summary: "Update collider capsule half height",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setColliderShapeCapsuleHalfHeight(entityID: entity.rawValue,
                                                                                         halfHeight: clamped)])
            }
        )
    }

    private func colliderFrictionBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(Collider.self, for: entity)?.material.friction ?? 0.6
            },
            set: { [self] next in
                let clamped = max(0, next)
                guard scene.component(Collider.self, for: entity)?.material.friction != clamped else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_collider_friction",
                                          summary: "Update collider friction",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setColliderMaterialFriction(entityID: entity.rawValue,
                                                                                   value: clamped)])
            }
        )
    }

    private func colliderRestitutionBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(Collider.self, for: entity)?.material.restitution ?? 0
            },
            set: { [self] next in
                let clamped = max(0, min(next, 1))
                guard scene.component(Collider.self, for: entity)?.material.restitution != clamped else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_collider_restitution",
                                          summary: "Update collider restitution",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setColliderMaterialRestitution(entityID: entity.rawValue,
                                                                                      value: clamped)])
            }
        )
    }

    private func colliderDensityBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(Collider.self, for: entity)?.material.density ?? 1
            },
            set: { [self] next in
                let clamped = max(0, next)
                guard scene.component(Collider.self, for: entity)?.material.density != clamped else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_collider_density",
                                          summary: "Update collider density",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setColliderMaterialDensity(entityID: entity.rawValue,
                                                                                  value: clamped)])
            }
        )
    }

    private func colliderLayerBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                Float(scene.component(Collider.self, for: entity)?.layerID ?? 0)
            },
            set: { [self] next in
                let clamped = UInt16(max(0, min(next, 65535)))
                guard scene.component(Collider.self, for: entity)?.layerID != clamped else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_collider_layer",
                                          summary: "Update collider layer",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setColliderLayer(entityID: entity.rawValue,
                                                                        layerID: clamped)])
            }
        )
    }

    private func constraintEnabledBinding(for entity: EntityID) -> Binding<Bool> {
        Binding(
            get: { [self] in
                scene.component(Constraint.self, for: entity)?.isEnabled ?? false
            },
            set: { [self] next in
                guard scene.component(Constraint.self, for: entity)?.isEnabled != next else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_constraint_enabled",
                                          summary: "Update constraint enabled flag",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setConstraintEnabled(entityID: entity.rawValue, value: next)])
            }
        )
    }

    private func lightColorBinding(for entity: EntityID) -> Binding<Color> {
        Binding(
            get: { [self] in
                let linear = scene.component(LightComponent.self, for: entity)?.color ?? SIMD3<Float>(1, 1, 1)
                return Color(r: linear.x, g: linear.y, b: linear.z, a: 1)
            },
            set: { [self] next in
                let nextColor = SIMD3<Float>(
                    max(0, min(1, next.r)),
                    max(0, min(1, next.g)),
                    max(0, min(1, next.b))
                )
                guard scene.component(LightComponent.self, for: entity)?.color != nextColor else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_light_color",
                                          summary: "Update light color",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setLightColor(entityID: entity.rawValue, color: nextColor)])
            }
        )
    }

    private func lightIntensityBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(LightComponent.self, for: entity)?.intensity ?? 1
            },
            set: { [self] next in
                let clamped = max(0, next)
                guard scene.component(LightComponent.self, for: entity)?.intensity != clamped else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_light_intensity",
                                          summary: "Update light intensity",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setLightIntensity(entityID: entity.rawValue, intensity: clamped)])
            }
        )
    }

    private func lightRangeBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(LightComponent.self, for: entity)?.range ?? 10
            },
            set: { [self] next in
                let clamped = max(0, next)
                guard scene.component(LightComponent.self, for: entity)?.range != clamped else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_light_range",
                                          summary: "Update light range",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setLightRange(entityID: entity.rawValue, range: clamped)])
            }
        )
    }

    private func lightSpotInnerAngleBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(LightComponent.self, for: entity)?.spotInnerAngleDegrees ?? 20
            },
            set: { [self] next in
                let currentOuter = scene.component(LightComponent.self, for: entity)?.spotOuterAngleDegrees ?? 30
                let clamped = max(0, min(currentOuter, next))
                guard scene.component(LightComponent.self, for: entity)?.spotInnerAngleDegrees != clamped else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_light_spot_inner_angle",
                                          summary: "Update spotlight inner angle",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setLightSpotInnerAngle(entityID: entity.rawValue, angleDegrees: clamped)])
            }
        )
    }

    private func lightSpotOuterAngleBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(LightComponent.self, for: entity)?.spotOuterAngleDegrees ?? 30
            },
            set: { [self] next in
                let clamped = max(1, min(179, next))
                guard scene.component(LightComponent.self, for: entity)?.spotOuterAngleDegrees != clamped else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_light_spot_outer_angle",
                                          summary: "Update spotlight outer angle",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setLightSpotOuterAngle(entityID: entity.rawValue, angleDegrees: clamped)])
            }
        )
    }

    private func scriptEnabledBinding(for entity: EntityID, index: Int) -> Binding<Bool> {
        Binding(
            get: { [self] in
                guard let bindings = scene.component(ScriptComponent.self, for: entity)?.bindings,
                      bindings.indices.contains(index)
                else { return false }
                return bindings[index].isEnabled
            },
            set: { [self] next in
                guard var bindings = scene.component(ScriptComponent.self, for: entity)?.bindings,
                      bindings.indices.contains(index),
                      bindings[index].isEnabled != next
                else { return }
                bindings[index].isEnabled = next
                _ = applySceneTransaction(intentVerb: "scene.set_script_enabled",
                                          summary: "Update script enabled flag",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setScriptBindings(entityID: entity.rawValue,
                                                                         bindings: bindings)])
            }
        )
    }

    private func scriptParametersBinding(for entity: EntityID, index: Int) -> Binding<String> {
        Binding(
            get: { [self] in
                guard let bindings = scene.component(ScriptComponent.self, for: entity)?.bindings,
                      bindings.indices.contains(index)
                else { return "{}" }
                return normalizedJSONCommitText(bindings[index].parametersJSON)
            },
            set: { [self] next in
                let normalized = normalizedJSONCommitText(next)
                guard isValidJSONDocument(normalized),
                      var bindings = scene.component(ScriptComponent.self, for: entity)?.bindings,
                      bindings.indices.contains(index),
                      bindings[index].parametersJSON != normalized
                else { return }
                bindings[index].parametersJSON = normalized
                _ = applySceneTransaction(intentVerb: "scene.set_script_parameters",
                                          summary: "Update script parameters",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setScriptBindings(entityID: entity.rawValue,
                                                                         bindings: bindings)])
            }
        )
    }

    private func publishRevision() {
        onRevisionChanged?(scene.snapshot.revision)
    }

    func notifyRevisionChanged() {
        onRevisionChanged?(scene.snapshot.revision)
    }

    private func displayName(for entity: EntityID) -> String {
        scene.component(SceneNameComponent.self, for: entity)?.value ?? fallbackName(for: entity)
    }

    private func displayKind(for entity: EntityID) -> String {
        if let kind = scene.component(SceneKindComponent.self, for: entity)?.value {
            return kind
        }
        if scene.hasComponent(Constraint.self, for: entity) {
            return "Constraint"
        }
        if scene.hasComponent(RigidBody.self, for: entity) || scene.hasComponent(Collider.self, for: entity) {
            return "Physics Entity"
        }
        if scene.hasComponent(ScriptComponent.self, for: entity) {
            return "Scripted Entity"
        }
        return "Entity"
    }

    private func fallbackName(for entity: EntityID) -> String {
        "Entity \(entity.index)"
    }

    private func meshColliderResourceID(for meshIndex: Int) -> String {
        "meshIndex:\(meshIndex)"
    }

    private func describe(_ shape: ColliderShape) -> String {
        switch shape {
        case let .box(halfExtents, _):
            return "Box \(format(halfExtents * 2))"
        case let .sphere(radius, _):
            return "Sphere r=\(format(radius))"
        case let .capsule(radius, halfHeight, _):
            return "Capsule r=\(format(radius)) h=\(format(halfHeight * 2))"
        case let .mesh(resourceID, _):
            return resourceID.map { "Mesh \($0)" } ?? "Mesh"
        case let .convex(resourceID, _):
            return resourceID.map { "Convex \($0)" } ?? "Convex"
        }
    }

    private func format(_ value: SIMD3<Float>) -> String {
        "\(format(value.x)), \(format(value.y)), \(format(value.z))"
    }

    private func format(_ value: Float) -> String {
        String(format: "%.2f", value)
    }

    private func entity(from rawID: UInt64?) -> EntityID? {
        guard let rawID else { return nil }
        return EntityID(rawValue: rawID)
    }

    // MARK: - Transform bindings

    private func localPositionBinding(for entity: EntityID,
                                      axis: WritableKeyPath<SIMD3<Float>, Float>) -> Binding<Float> {
        Binding(
            get: { [self] in
                let t = scene.localTransform(for: entity)?.translation ?? .zero
                return t[keyPath: axis]
            },
            set: { [self] next in
                var local = scene.localTransform(for: entity) ?? LocalTransform()
                var translation = local.translation
                guard translation[keyPath: axis] != next else { return }
                translation[keyPath: axis] = next
                local.matrix.columns.3 = SIMD4<Float>(translation, 1)
                _ = applySceneTransaction(intentVerb: "scene.set_local_transform",
                                          summary: "Update entity translation",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setLocalTransform(entityID: entity.rawValue, transform: local)])
            }
        )
    }

    private func localScaleBinding(for entity: EntityID,
                                   axis: WritableKeyPath<SIMD3<Float>, Float>) -> Binding<Float> {
        Binding(
            get: { [self] in
                let m = scene.localTransform(for: entity)?.matrix ?? matrix_identity_float4x4
                let (_, scale) = decomposeRotationScale(m)
                return scale[keyPath: axis]
            },
            set: { [self] next in
                var local = scene.localTransform(for: entity) ?? LocalTransform()
                let (rot, _) = decomposeRotationScale(local.matrix)
                let translation = SIMD3<Float>(local.matrix.columns.3.x,
                                               local.matrix.columns.3.y,
                                               local.matrix.columns.3.z)
                var scale = decomposeRotationScale(local.matrix).1
                guard scale[keyPath: axis] != next else { return }
                scale[keyPath: axis] = next
                local.matrix = composeMatrix(translation: translation, rotation: rot, scale: scale)
                _ = applySceneTransaction(intentVerb: "scene.set_local_transform",
                                          summary: "Update entity scale",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setLocalTransform(entityID: entity.rawValue, transform: local)])
            }
        )
    }

    private func localRotationBinding(for entity: EntityID,
                                      axis: WritableKeyPath<SIMD3<Float>, Float>) -> Binding<Float> {
        Binding(
            get: { [self] in
                let m = scene.localTransform(for: entity)?.matrix ?? matrix_identity_float4x4
                let (rot, _) = decomposeRotationScale(m)
                let euler = eulerXYZFromMatrix(rot)
                let deg = euler * (180.0 / .pi)
                return deg[keyPath: axis]
            },
            set: { [self] next in
                var local = scene.localTransform(for: entity) ?? LocalTransform()
                let (_, scale) = decomposeRotationScale(local.matrix)
                let translation = SIMD3<Float>(local.matrix.columns.3.x,
                                               local.matrix.columns.3.y,
                                               local.matrix.columns.3.z)
                let currentDegrees = eulerXYZFromMatrix(decomposeRotationScale(local.matrix).0) * (180.0 / .pi)
                guard currentDegrees[keyPath: axis] != next else { return }
                var degrees = currentDegrees
                degrees[keyPath: axis] = next
                let radians = degrees * (.pi / 180.0)
                let rot = matrixFromEulerXYZ(radians)
                local.matrix = composeMatrix(translation: translation, rotation: rot, scale: scale)
                _ = applySceneTransaction(intentVerb: "scene.set_local_transform",
                                          summary: "Update entity rotation",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setLocalTransform(entityID: entity.rawValue, transform: local)])
            }
        )
    }

    @discardableResult
    func applySceneTransaction(intentVerb: String,
                               summary: String,
                               targetRawIDs: [UInt64] = [],
                               mutations: [SceneMutation]) -> TransactionApplyResult? {
        let intent = IntentIR(verb: intentVerb,
                              summary: summary,
                              targetObjectIDs: targetRawIDs.map { "scene:\($0)" },
                              source: .human)
        let transaction = TransactionIR(intent: intent,
                                        summary: summary,
                                        operations: mutations.map(TransactionOperation.scene),
                                        baseRevisions: TransactionBaseRevisions(sceneRevision: scene.snapshot.revision),
                                        provenance: .authored)
        var context = TransactionExecutionContext(sceneRuntime: scene)
        guard let result = try? transactionExecutor.apply(transaction, to: &context),
              let updatedScene = context.sceneRuntime
        else {
            return nil
        }
        scene = updatedScene
        notifyRevisionChanged()
        return result
    }

}

private extension EntityID {
    init?(rawValue: UInt64) {
        self.init(
            index: UInt32(rawValue & 0xFFFF_FFFF),
            generation: UInt32(rawValue >> 32)
        )
    }
}

// MARK: - Transform decompose / compose

/// 鎶?4x4 鏈湴鐭╅樀鍒嗚В鎴愮函鏃嬭浆 3x3 + per-axis 缂╂斁鍚戦噺銆?
/// 鍋囪鐭╅樀涓嶅惈鍒囧彉锛涘鏋滄湁鍒囧彉锛岀缉鏀惧彧鍙栧垪闀垮害杩戜技銆?
private func decomposeRotationScale(_ m: simd_float4x4) -> (simd_float3x3, SIMD3<Float>) {
    let c0 = SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z)
    let c1 = SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z)
    let c2 = SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z)
    let sx = simd_length(c0)
    let sy = simd_length(c1)
    let sz = simd_length(c2)
    let r0 = sx > 1e-5 ? c0 / sx : SIMD3<Float>(1, 0, 0)
    let r1 = sy > 1e-5 ? c1 / sy : SIMD3<Float>(0, 1, 0)
    let r2 = sz > 1e-5 ? c2 / sz : SIMD3<Float>(0, 0, 1)
    return (simd_float3x3(columns: (r0, r1, r2)), SIMD3<Float>(sx, sy, sz))
}

private func composeMatrix(translation: SIMD3<Float>,
                           rotation: simd_float3x3,
                           scale: SIMD3<Float>) -> simd_float4x4 {
    let c0 = rotation.columns.0 * scale.x
    let c1 = rotation.columns.1 * scale.y
    let c2 = rotation.columns.2 * scale.z
    var m = matrix_identity_float4x4
    m.columns.0 = SIMD4<Float>(c0, 0)
    m.columns.1 = SIMD4<Float>(c1, 0)
    m.columns.2 = SIMD4<Float>(c2, 0)
    m.columns.3 = SIMD4<Float>(translation, 1)
    return m
}

private func normalizedJSONCommitText(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "{}" : trimmed
}

private func isValidJSONDocument(_ text: String) -> Bool {
    guard let data = text.data(using: .utf8) else { return false }
    do {
        _ = try JSONSerialization.jsonObject(with: data)
        return true
    } catch {
        return false
    }
}

/// 浠?3x3 鏃嬭浆鐭╅樀鎻愬彇 Euler XYZ锛坕ntrinsic 椤哄簭锛歊 = Rx * Ry * Rz锛夈€?
/// 杩欓噷 simd 鏄?column-major锛歮[c][r] 绛変环鏁板绾﹀畾 R[r][c]銆?
private func eulerXYZFromMatrix(_ m: simd_float3x3) -> SIMD3<Float> {
    // R[r][c] = m.columns[c][r]
    let r02 = m.columns.2.x // R[0][2]
    let r12 = m.columns.2.y // R[1][2]
    let r22 = m.columns.2.z // R[2][2]
    let r00 = m.columns.0.x // R[0][0]
    let r01 = m.columns.1.x // R[0][1]

    let sy = max(-1, min(1, r02))
    let y = asinf(sy)
    let cy = cosf(y)
    let x: Float
    let z: Float
    if abs(cy) > 1e-4 {
        x = atan2f(-r12, r22)
        z = atan2f(-r01, r00)
    } else {
        // gimbal lock: 璁?z = 0 瑙?x銆?
        x = atan2f(m.columns.0.y, m.columns.1.y) // atan2(R[1][0], R[1][1])
        z = 0
    }
    return SIMD3<Float>(x, y, z)
}

/// 浠?Euler XYZ锛堝姬搴︼紝intrinsic锛夊悎鎴?3x3 鏃嬭浆鐭╅樀锛歊 = Rx * Ry * Rz銆?
private func matrixFromEulerXYZ(_ e: SIMD3<Float>) -> simd_float3x3 {
    let cx = cosf(e.x), sx = sinf(e.x)
    let cy = cosf(e.y), sy = sinf(e.y)
    let cz = cosf(e.z), sz = sinf(e.z)

    // R = Rx * Ry * Rz
    // 閫愰」灞曞紑
    let r00 = cy * cz
    let r01 = -cy * sz
    let r02 = sy
    let r10 = sx * sy * cz + cx * sz
    let r11 = -sx * sy * sz + cx * cz
    let r12 = -sx * cy
    let r20 = -cx * sy * cz + sx * sz
    let r21 = cx * sy * sz + sx * cz
    let r22 = cx * cy

    // simd column-major: columns[c][r] = R[r][c]
    return simd_float3x3(columns: (
        SIMD3<Float>(r00, r10, r20),
        SIMD3<Float>(r01, r11, r21),
        SIMD3<Float>(r02, r12, r22)
    ))
}
