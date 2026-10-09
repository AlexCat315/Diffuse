import AssetPipeline
import SceneRuntime
import SIMDCompat

public struct EditorRagdollGenerationResult: Sendable, Equatable {
    public var bodyCount: Int
    public var jointCount: Int
    public var error: String?

    public init(bodyCount: Int = 0, jointCount: Int = 0, error: String? = nil) {
        self.bodyCount = bodyCount
        self.jointCount = jointCount
        self.error = error
    }
}

extension EditorSceneAdapter {
    /// Generates a playable first-pass ragdoll from the first skin of the entity's mesh.
    /// Bodies and joints are created as children of the selected skinned entity so the
    /// result remains editable and serializable like ordinary scene physics components.
    @discardableResult
    public func generateRagdoll(for rawID: UInt64) -> EditorRagdollGenerationResult {
        let root = EntityID(rawValue: rawID)
        guard scene.contains(root) else {
            return EditorRagdollGenerationResult(error: "Entity not found")
        }
        guard !scene.hasComponent(Ragdoll.self, for: root) else {
            return EditorRagdollGenerationResult(error: "Entity already has a ragdoll")
        }
        guard let asset = scene.component(AssetReferenceComponent.self, for: root),
              let mesh = AssetRegistry.shared.meshAsset(for: asset.meshIndex),
              let skin = mesh.skins.first,
              !skin.jointNodeIndices.isEmpty else {
            return EditorRagdollGenerationResult(error: "Skinned mesh data is unavailable")
        }

        let nodeWorld = ragdollNodeWorldMatrices(mesh.nodes)
        let jointSet = Set(skin.jointNodeIndices)
        let rootName = scene.component(SceneNameComponent.self, for: root)?.value ?? "Ragdoll"
        var bodyByNode: [Int: EntityID] = [:]
        var mappings: [RagdollBoneMapping] = []

        for (paletteIndex, nodeIndex) in skin.jointNodeIndices.enumerated() {
            guard mesh.nodes.indices.contains(nodeIndex), nodeWorld.indices.contains(nodeIndex) else { continue }
            let node = mesh.nodes[nodeIndex]
            let boneName = node.name ?? "bone_\(nodeIndex)"
            let childIndex = skin.jointNodeIndices.first {
                mesh.nodes.indices.contains($0) && mesh.nodes[$0].parentIndex == nodeIndex
            }
            let childOffset: SIMD3<Float>? = childIndex.flatMap { child in
                guard nodeWorld.indices.contains(child) else { return nil }
                let local = simd_inverse(nodeWorld[nodeIndex]) * nodeWorld[child]
                return SIMD3<Float>(local.columns.3.x, local.columns.3.y, local.columns.3.z)
            }
            let length = max(0.15, childOffset.map(simd_length) ?? 0.25)
            let radius = max(0.04, min(length * 0.2, 0.15))
            let body = scene.createEntity()
            _ = scene.setComponent(SceneNameComponent(value: "\(rootName) \(boneName) Body"), for: body)
            _ = scene.setComponent(SceneKindComponent(value: "Ragdoll Body"), for: body)
            _ = scene.setLocalTransform(LocalTransform(matrix: nodeWorld[nodeIndex]), for: body)
            _ = scene.setParent(root, for: body)
            _ = scene.setComponent(RigidBody(
                motionType: .kinematic,
                mass: max(0.25, length),
                gravityScale: 1,
                allowSleep: true
            ), for: body)
            let collider: Collider
            if let childOffset, simd_length_squared(childOffset) > 0.0001 {
                let direction = simd_normalize(childOffset)
                let rotation = ragdollRotationFromY(to: direction)
                collider = Collider(shapes: [ColliderShapeInstance(
                    shape: .capsule(
                        radius: radius,
                        halfHeight: max(0.01, length * 0.5 - radius),
                        center: .zero
                    ),
                    localPosition: childOffset * 0.5,
                    localRotation: rotation.vector
                )])
            } else {
                collider = Collider(shape: .sphere(radius: radius, center: .zero))
            }
            _ = scene.setComponent(collider, for: body)
            bodyByNode[nodeIndex] = body
            let inverseBind = skin.inverseBindMatrices.indices.contains(paletteIndex)
                ? skin.inverseBindMatrices[paletteIndex]
                : matrix_identity_float4x4
            mappings.append(RagdollBoneMapping(
                boneName: boneName,
                paletteIndex: paletteIndex,
                bodyEntity: body,
                bodyFromPalette: simd_inverse(inverseBind)
            ))
        }

        var jointCount = 0
        for nodeIndex in skin.jointNodeIndices {
            guard let body = bodyByNode[nodeIndex],
                  let parentIndex = mesh.nodes[nodeIndex].parentIndex,
                  jointSet.contains(parentIndex),
                  let parentBody = bodyByNode[parentIndex]
            else { continue }
            let jointEntity = scene.createEntity()
            let boneName = mesh.nodes[nodeIndex].name ?? "bone_\(nodeIndex)"
            _ = scene.setComponent(SceneNameComponent(value: "\(rootName) \(boneName) Joint"), for: jointEntity)
            _ = scene.setComponent(SceneKindComponent(value: "Ragdoll Joint"), for: jointEntity)
            _ = scene.setLocalTransform(.identity, for: jointEntity)
            _ = scene.setParent(root, for: jointEntity)
            let currentInParent = simd_inverse(nodeWorld[parentIndex]) * nodeWorld[nodeIndex]
            let pivotA = SIMD3<Float>(
                currentInParent.columns.3.x,
                currentInParent.columns.3.y,
                currentInParent.columns.3.z
            )
            _ = scene.setComponent(PhysicsJoint(
                configuration: .cone(ConeJointConfiguration(
                    halfConeAngle: 0.65,
                    minimumTwistAngle: -0.35,
                    maximumTwistAngle: 0.35
                )),
                entityA: parentBody,
                entityB: body,
                pivotA: pivotA,
                pivotB: .zero
            ), for: jointEntity)
            if let mappingIndex = mappings.firstIndex(where: { $0.bodyEntity == body }) {
                mappings[mappingIndex].jointEntity = jointEntity
            }
            jointCount += 1
        }

        _ = scene.setComponent(Ragdoll(mode: .animated, bones: mappings), for: root)
        scene.propagateTransforms()
        notifyRevisionChanged()
        return EditorRagdollGenerationResult(bodyCount: mappings.count, jointCount: jointCount)
    }
}

private func ragdollNodeWorldMatrices(_ nodes: [MeshNode]) -> [simd_float4x4] {
    var result = Array(repeating: matrix_identity_float4x4, count: nodes.count)
    var resolved = Array(repeating: false, count: nodes.count)
    func resolve(_ index: Int) -> simd_float4x4 {
        guard nodes.indices.contains(index) else { return matrix_identity_float4x4 }
        if resolved[index] { return result[index] }
        let parent = nodes[index].parentIndex.map(resolve) ?? matrix_identity_float4x4
        result[index] = parent * nodes[index].localMatrix
        resolved[index] = true
        return result[index]
    }
    for index in nodes.indices { _ = resolve(index) }
    return result
}

private func ragdollRotationFromY(to direction: SIMD3<Float>) -> simd_quatf {
    let y = SIMD3<Float>(0, 1, 0)
    let cosine = max(-1, min(simd_dot(y, direction), 1))
    if cosine > 0.9999 { return simd_quatf(angle: 0, axis: y) }
    if cosine < -0.9999 { return simd_quatf(angle: .pi, axis: SIMD3<Float>(1, 0, 0)) }
    return simd_quatf(angle: acos(cosine), axis: simd_normalize(simd_cross(y, direction)))
}
