import Foundation
import AssetPipeline
import GuavaUIRuntime
import IntentRuntime
import RenderBackend
import SceneRuntime
import ScriptRuntime
import SIMDCompat

public struct EditorSceneManifestSoftBody: Codable, Sendable, Equatable {
    public let vertexMass: Float
    public let pressure: Float
    public let linearDamping: Float
    public let friction: Float
    public let restitution: Float
    public let gravityScale: Float
    public let vertexRadius: Float
    public let solverIterations: Int
    public let maxLinearVelocity: Float
    public let layerID: UInt16
    public let layerMask: UInt16
    public let allowSleep: Bool
    public let facesDoubleSided: Bool
    public let selfCollision: Bool
    public let isEnabled: Bool

    public init(_ body: SoftBody) {
        vertexMass = body.vertexMass
        pressure = body.pressure
        linearDamping = body.linearDamping
        friction = body.friction
        restitution = body.restitution
        gravityScale = body.gravityScale
        vertexRadius = body.vertexRadius
        solverIterations = body.solverIterations
        maxLinearVelocity = body.maxLinearVelocity
        layerID = body.layerID
        layerMask = body.layerMask
        allowSleep = body.allowSleep
        facesDoubleSided = body.facesDoubleSided
        selfCollision = body.selfCollision
        isEnabled = body.isEnabled
    }

    var component: SoftBody {
        SoftBody(
            vertexMass: vertexMass,
            pressure: pressure,
            linearDamping: linearDamping,
            friction: friction,
            restitution: restitution,
            gravityScale: gravityScale,
            vertexRadius: vertexRadius,
            solverIterations: solverIterations,
            maxLinearVelocity: maxLinearVelocity,
            layerID: layerID,
            layerMask: layerMask,
            allowSleep: allowSleep,
            facesDoubleSided: facesDoubleSided,
            selfCollision: selfCollision,
            isEnabled: isEnabled
        )
    }
}

public struct EditorSceneManifestCloth: Codable, Sendable, Equatable {
    public let gridSizeX: Int
    public let gridSizeZ: Int
    public let spacing: Float
    public let fixedVertexIndices: [Int]
    public let compliance: Float
    public let shearCompliance: Float
    public let bendCompliance: Float
    public let bendType: String

    public init(_ cloth: Cloth) {
        gridSizeX = cloth.gridSizeX
        gridSizeZ = cloth.gridSizeZ
        spacing = cloth.spacing
        fixedVertexIndices = cloth.fixedVertexIndices
        compliance = cloth.compliance
        shearCompliance = cloth.shearCompliance
        bendCompliance = cloth.bendCompliance
        bendType = String(describing: cloth.bendType)
    }

    var component: Cloth {
        Cloth(
            gridSizeX: gridSizeX,
            gridSizeZ: gridSizeZ,
            spacing: spacing,
            fixedVertexIndices: fixedVertexIndices,
            compliance: compliance,
            shearCompliance: shearCompliance,
            bendCompliance: bendCompliance,
            bendType: ClothBendType.allCases.first {
                String(describing: $0) == bendType
            } ?? .distance
        )
    }
}

public struct EditorSceneManifestSoftBodyMesh: Codable, Sendable, Equatable {
    public let resourceID: String?
    public let fixedVertexIndices: [Int]
    public let compliance: Float
    public let shearCompliance: Float
    public let bendCompliance: Float
    public let volumeCompliance: Float?
    public let bendType: String

    public init(_ mesh: SoftBodyMesh) {
        resourceID = mesh.resourceID
        fixedVertexIndices = mesh.fixedVertexIndices
        compliance = mesh.compliance
        shearCompliance = mesh.shearCompliance
        bendCompliance = mesh.bendCompliance
        volumeCompliance = mesh.volumeCompliance
        bendType = String(describing: mesh.bendType)
    }

    var component: SoftBodyMesh {
        SoftBodyMesh(
            resourceID: resourceID,
            fixedVertexIndices: fixedVertexIndices,
            compliance: compliance,
            shearCompliance: shearCompliance,
            bendCompliance: bendCompliance,
            volumeCompliance: volumeCompliance ?? 1.0e-6,
            bendType: ClothBendType.allCases.first {
                String(describing: $0) == bendType
            } ?? .dihedral
        )
    }
}
