import EngineKernel
import SIMDCompat

extension RuntimeWorldSchedule {
    mutating func extractRenderScene(
        in world: RuntimeWorld
    ) -> (resource: ExtractedRenderSceneResource, report: JobDispatchReport) {
        let view = buildRenderReadView(in: world)
        let cameraSelection = selectRenderCamera(from: view)
        let deformableMeshes = collectRenderDeformableMeshes(in: world, from: view)
        let deformableEntities = Set(deformableMeshes.map(\.entity))
        let instanceCollection = collectRenderInstances(
            from: view,
            deformableEntities: deformableEntities
        )
        let lightCollection = collectRenderLights(from: view)
        let instances = instanceCollection.instances
        let lights = lightCollection.lights
        let particleCollection = collectRenderParticles(in: world, camera: cameraSelection.camera)
        let particleSimulationBatches = collectParticleSimulationBatches(in: world,
                                                                         camera: cameraSelection.camera)
        let particleSummary = ParticleRenderSummary(
            particles: particleCollection.particles,
            simulationBatches: particleSimulationBatches,
            cpuSourceParticleCount: particleCollection.sourceParticleCount,
            cpuSubmittedSourceParticleCount: particleCollection.submittedSourceParticleCount
        )
        return (
            ExtractedRenderSceneResource(
                scene: RenderScene(
                    camera: cameraSelection.camera,
                    instances: instances.map(\.instance),
                    lights: lights.map(\.light),
                    deformableMeshes: deformableMeshes,
                    particles: particleCollection.particles,
                    particleSimulationBatches: particleSimulationBatches,
                    particleSummary: particleSummary
                ),
                activeCameraEntity: cameraSelection.entity,
                instanceEntities: instances.map(\.entity),
                lightEntities: lights.map(\.entity),
                sourceRevision: world.revision
            ),
            mergeDispatchReports([cameraSelection.report, instanceCollection.report, lightCollection.report])
        )
    }


    func selectRenderCamera(
        from view: RuntimeRenderReadView
    ) -> (entity: EntityID?, camera: RenderCamera, report: JobDispatchReport) {
        let candidates = jobSystem.parallelCompactMap(items: view.entities) { entity -> (EntityID, RenderCamera, Bool)? in
            guard let component = view.cameras[entity] else {
                return nil
            }

            let camera = RenderCamera(
                eye: view.worldTransforms[entity]?.translation ?? .zero,
                target: component.target,
                up: component.up,
                fovYRadians: component.fovYRadians,
                aspectRatio: component.aspectRatio,
                near: component.near,
                far: component.far
            )
            return (entity, camera, component.isActive)
        }

        var fallbackSelection: (entity: EntityID?, camera: RenderCamera)?
        for candidate in candidates.0 {
            if fallbackSelection == nil {
                fallbackSelection = (candidate.0, candidate.1)
            }
            if candidate.2 {
                return (candidate.0, candidate.1, candidates.1)
            }
        }

        let resolved = fallbackSelection ?? (nil, .fallbackPerspective)
        return (resolved.entity, resolved.camera, candidates.1)
    }

    func collectRenderInstances(
        from view: RuntimeRenderReadView,
        deformableEntities: Set<EntityID> = []
    ) -> (instances: [ExtractedRenderInstance], report: JobDispatchReport) {
        let result = jobSystem.parallelCompactMap(items: view.entities) { entity -> ExtractedRenderInstance? in
            guard let renderMesh = view.renderMeshes[entity],
                  renderMesh.isVisible,
                  let worldTransform = view.worldTransforms[entity]
            else {
                return nil
            }

            return ExtractedRenderInstance(
                entity: entity,
                instance: RenderInstance(
                    mesh: RenderMeshHandle(meshIndex: renderMesh.meshIndex,
                                           assetID: renderMesh.assetID ?? view.assetReferences[entity]?.assetID,
                                           levelsOfDetail: renderMesh.levelsOfDetail),
                    // Jolt streams soft-body vertices in world space. Drawing
                    // them with the authored ECS transform would apply it twice.
                    transform: deformableEntities.contains(entity)
                        ? matrix_identity_float4x4
                        : worldTransform.matrix,
                    colorTint: renderMesh.colorTint,
                    material: view.renderMaterials[entity]?.renderMaterial ?? .fallback,
                    entity: entity
                )
            )
        }
        return (result.0, result.1)
    }

    mutating func collectRenderDeformableMeshes(
        in world: RuntimeWorld,
        from view: RuntimeRenderReadView
    ) -> [RenderDeformableMesh] {
        let states = world.resource(SoftBodyStateFrameResource.self)?.states
            ?? softBodyStateFrame.states
        let simulatedRevision = UInt64(max(
            0,
            world.resource(PhysicsStepClockResource.self)?.simulatedSteps
                ?? physicsClock.simulatedSteps
        ))
        var meshes: [RenderDeformableMesh] = []
        for state in states.values.sorted(by: {
            $0.entity.rawValue < $1.entity.rawValue
        }) {
            guard !state.positions.isEmpty,
                  !state.triangleIndices.isEmpty,
                  view.renderMeshes[state.entity]?.isVisible == true
            else { continue }
            let textureCoordinates = clothTextureCoordinates(
                view.cloths[state.entity],
                vertexCount: state.positions.count
            )
            let resolvedTextureCoordinates: [SIMD2<Float>]
            if textureCoordinates.isEmpty,
               let geometry = view.softBodyMeshGeometries[state.entity],
               geometry.textureCoordinates.count == state.positions.count {
                resolvedTextureCoordinates = geometry.textureCoordinates
            } else {
                resolvedTextureCoordinates = textureCoordinates
            }
            if let cached = renderDeformableMeshes[state.entity],
               cached.positions == state.positions,
               cached.triangleIndices == state.triangleIndices,
               cached.textureCoordinates == resolvedTextureCoordinates {
                meshes.append(cached)
                continue
            }
            let previousRevision = renderDeformableMeshes[state.entity]?.revision ?? 0
            let nextRevision = previousRevision == UInt64.max
                ? previousRevision
                : previousRevision + 1
            let mesh = RenderDeformableMesh(
                entity: state.entity,
                revision: max(simulatedRevision, nextRevision),
                positions: state.positions,
                triangleIndices: state.triangleIndices,
                textureCoordinates: resolvedTextureCoordinates
            )
            if mesh.isValid {
                meshes.append(mesh)
            }
        }
        renderDeformableMeshes = Dictionary(
            uniqueKeysWithValues: meshes.map { ($0.entity, $0) }
        )
        return meshes
    }

    func clothTextureCoordinates(
        _ cloth: Cloth?,
        vertexCount: Int
    ) -> [SIMD2<Float>] {
        guard let cloth, cloth.vertexCount == vertexCount else { return [] }
        let denominatorX = Float(max(1, cloth.gridSizeX - 1))
        let denominatorZ = Float(max(1, cloth.gridSizeZ - 1))
        return (0..<vertexCount).map { index in
            let x = index % cloth.gridSizeX
            let z = index / cloth.gridSizeX
            return SIMD2<Float>(Float(x) / denominatorX, Float(z) / denominatorZ)
        }
    }

    func collectRenderLights(
        from view: RuntimeRenderReadView
    ) -> (lights: [ExtractedRenderLight], report: JobDispatchReport) {
        let result = jobSystem.parallelCompactMap(items: view.entities) { entity -> ExtractedRenderLight? in
            guard let component = view.lights[entity] else {
                return nil
            }
            let worldTransform = view.worldTransforms[entity] ?? .identity
            return ExtractedRenderLight(
                entity: entity,
                light: RenderLight(
                    type: component.renderLightType,
                    position: worldTransform.translation,
                    direction: renderForwardDirection(from: worldTransform.matrix),
                    color: component.color,
                    intensity: component.intensity,
                    range: component.range,
                    spotInnerAngleRadians: degreesToRadians(component.spotInnerAngleDegrees),
                    spotOuterAngleRadians: degreesToRadians(component.spotOuterAngleDegrees),
                    castShadows: component.castShadows,
                    entity: entity
                )
            )
        }
        return (result.0, result.1)
    }

    func buildRenderReadView(in world: RuntimeWorld) -> RuntimeRenderReadView {
        let entities = world.entities()
        let softBodyMeshes = world.componentSnapshot(SoftBodyMesh.self, matching: entities)
        let geometryResource = world.resource(MeshColliderGeometryResource.self)
        var softBodyMeshGeometries: [EntityID: MeshColliderGeometry] = [:]
        for (entity, mesh) in softBodyMeshes {
            if let geometry = geometryResource?.geometry(for: mesh.resourceID) {
                softBodyMeshGeometries[entity] = geometry
            }
        }
        return RuntimeRenderReadView(
            entities: entities,
            worldTransforms: world.worldTransformSnapshot(matching: entities),
            cameras: world.componentSnapshot(CameraComponent.self, matching: entities),
            renderMeshes: world.componentSnapshot(RenderMeshComponent.self, matching: entities),
            renderMaterials: world.componentSnapshot(RenderMaterialComponent.self, matching: entities),
            lights: world.componentSnapshot(LightComponent.self, matching: entities),
            cloths: world.componentSnapshot(Cloth.self, matching: entities),
            softBodyMeshes: softBodyMeshes,
            softBodyMeshGeometries: softBodyMeshGeometries,
            assetReferences: world.componentSnapshot(AssetReferenceComponent.self, matching: entities)
        )
    }
}

private extension LightComponent {
    var renderLightType: RenderLightType {
        switch type {
        case .directional:
            return .directional
        case .point:
            return .point
        case .spot:
            return .spot
        }
    }
}

private func degreesToRadians(_ degrees: Float) -> Float {
    degrees * .pi / 180
}

private func renderForwardDirection(from matrix: simd_float4x4) -> SIMD3<Float> {
    let forward = -SIMD3<Float>(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z)
    let lengthSquared = simd_length_squared(forward)
    guard lengthSquared > 0.000001 else {
        return SIMD3<Float>(0, 0, -1)
    }
    return forward / sqrt(lengthSquared)
}
