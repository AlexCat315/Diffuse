import SIMDCompat

extension RuntimeWorldSchedule {
    mutating func applyRagdollAnimationToBodies(in world: inout RuntimeWorld) {
        let paletteMap = world.resource(JointPaletteMap.self) ?? JointPaletteMap()
        var nextSimulatedBodies: Set<EntityID> = []
        for entity in world.entities(with: Ragdoll.self).sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let ragdoll = world.component(Ragdoll.self, for: entity),
                  let rootWorld = world.worldTransform(for: entity)
            else { continue }
            let palette = paletteMap.palette(for: entity)?.matrices ?? []
            for bone in ragdoll.bones {
                guard world.contains(bone.bodyEntity),
                      var rigidBody = world.component(RigidBody.self, for: bone.bodyEntity)
                else { continue }
                let shouldSimulate = ragdoll.isEnabled
                    && ragdoll.mode != .animated
                    && bone.isSimulationEnabled
                let paletteMatrix = palette.indices.contains(bone.paletteIndex)
                    ? palette[bone.paletteIndex]
                    : nil
                let desiredWorld = paletteMatrix.map {
                    WorldTransform(matrix: rootWorld.matrix * $0 * bone.bodyFromPalette)
                }

                if shouldSimulate {
                    if !ragdollSimulatedBodies.contains(bone.bodyEntity), let desiredWorld {
                        _ = world.applyPhysicsWriteback(PhysicsBodyWriteback(
                            entity: bone.bodyEntity,
                            worldTransform: desiredWorld
                        ))
                    }
                    rigidBody.motionType = bone.simulatedMotionType
                    rigidBody.kinematicTarget = nil
                    rigidBody.isSleeping = false
                    if desiredWorld != nil || ragdollSimulatedBodies.contains(bone.bodyEntity) {
                        nextSimulatedBodies.insert(bone.bodyEntity)
                    }
                } else {
                    rigidBody.motionType = .kinematic
                    if let desiredWorld {
                        let transform = LocalTransform(matrix: desiredWorld.matrix)
                        rigidBody.kinematicTarget = PhysicsKinematicTarget(
                            position: desiredWorld.translation,
                            rotation: transform.rotation.vector
                        )
                        _ = world.applyPhysicsWriteback(PhysicsBodyWriteback(
                            entity: bone.bodyEntity,
                            worldTransform: desiredWorld
                        ))
                    } else {
                        rigidBody.kinematicTarget = nil
                    }
                }
                _ = world.setComponent(rigidBody, for: bone.bodyEntity)
            }
        }
        ragdollSimulatedBodies = nextSimulatedBodies
    }

    func writeRagdollPhysicsToAnimation(in world: inout RuntimeWorld) {
        var paletteMap = world.resource(JointPaletteMap.self) ?? JointPaletteMap()
        var states: [EntityID: RagdollState] = [:]
        for entity in world.entities(with: Ragdoll.self).sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let ragdoll = world.component(Ragdoll.self, for: entity),
                  let rootWorld = world.worldTransform(for: entity)
            else { continue }
            var matrices = paletteMap.palette(for: entity)?.matrices ?? []
            let maximumIndex = ragdoll.bones.map { $0.paletteIndex }.max() ?? -1
            if matrices.count <= maximumIndex {
                matrices.append(contentsOf: repeatElement(
                    matrix_identity_float4x4,
                    count: maximumIndex + 1 - matrices.count
                ))
            }
            var boneStates: [RagdollBoneState] = []
            boneStates.reserveCapacity(ragdoll.bones.count)
            let inverseRoot = simd_inverse(rootWorld.matrix)
            for bone in ragdoll.bones {
                guard let bodyWorld = world.worldTransform(for: bone.bodyEntity) else { continue }
                let isSimulated = ragdoll.isEnabled
                    && ragdoll.mode != .animated
                    && bone.isSimulationEnabled
                let weight: Float
                switch ragdoll.mode {
                case .animated:
                    weight = 0
                case .simulated:
                    weight = isSimulated ? bone.blendWeight : 0
                case .blended:
                    weight = isSimulated ? ragdoll.blendWeight * bone.blendWeight : 0
                }
                if weight > 0, matrices.indices.contains(bone.paletteIndex) {
                    let physicsPalette = inverseRoot
                        * bodyWorld.matrix
                        * simd_inverse(bone.bodyFromPalette)
                    matrices[bone.paletteIndex] = blendTransformMatrices(
                        matrices[bone.paletteIndex],
                        physicsPalette,
                        weight: weight
                    )
                }
                boneStates.append(RagdollBoneState(
                    boneName: bone.boneName,
                    paletteIndex: bone.paletteIndex,
                    bodyEntity: bone.bodyEntity,
                    worldTransform: bodyWorld,
                    isSimulated: isSimulated
                ))
            }
            paletteMap.palettes[entity] = JointPalette(matrices: matrices)
            states[entity] = RagdollState(entity: entity, mode: ragdoll.mode, bones: boneStates)
        }
        world.setDerivedResource(paletteMap)
        world.setDerivedResource(RagdollStateFrameResource(states: states))
    }

    func blendTransformMatrices(
        _ animation: simd_float4x4,
        _ physics: simd_float4x4,
        weight: Float
    ) -> simd_float4x4 {
        let t = max(0, min(weight, 1))
        guard t > 0 else { return animation }
        guard t < 1 else { return physics }
        let animationTransform = LocalTransform(matrix: animation)
        let physicsTransform = LocalTransform(matrix: physics)
        let translation = simd_mix(
            animationTransform.translation,
            physicsTransform.translation,
            SIMD3<Float>(repeating: t)
        )
        let rotation = guavaSlerp(
            animationTransform.rotation,
            physicsTransform.rotation,
            t
        )
        let animationScale = transformScale(animation)
        let physicsScale = transformScale(physics)
        let scale = simd_mix(animationScale, physicsScale, SIMD3<Float>(repeating: t))
        var result = simd_float4x4(rotation)
        result.columns.0 *= scale.x
        result.columns.1 *= scale.y
        result.columns.2 *= scale.z
        result.columns.3 = SIMD4<Float>(translation, 1)
        return result
    }

    func transformScale(_ matrix: simd_float4x4) -> SIMD3<Float> {
        SIMD3<Float>(
            simd_length(SIMD3<Float>(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z)),
            simd_length(SIMD3<Float>(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z)),
            simd_length(SIMD3<Float>(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z))
        )
    }
}
