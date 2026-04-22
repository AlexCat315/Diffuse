import simd

public struct SceneNameComponent: RuntimeComponent, Sendable, Equatable {
    public var value: String

    public init(value: String) {
        self.value = value
    }
}

public struct SceneKindComponent: RuntimeComponent, Sendable, Equatable {
    public var value: String

    public init(value: String) {
        self.value = value
    }
}

public struct SceneBootstrapDefaultsResource: Sendable, Equatable {
    public var defaultSelection: EntityID?
    public var defaultExpanded: [EntityID]

    public init(defaultSelection: EntityID? = nil, defaultExpanded: [EntityID] = []) {
        self.defaultSelection = defaultSelection
        self.defaultExpanded = defaultExpanded
    }
}

public extension SceneRuntime {
    mutating func bootstrapEditorPreviewScene() {
        guard snapshot.entityCount == 0 else { return }

        let camera = makePreviewEntity(
            name: "Main Camera",
            kind: "Camera",
            matrix: previewTranslationMatrix(SIMD3<Float>(0, 2.4, 7.5))
        )
        _ = setComponent(
            CameraComponent(target: SIMD3<Float>(0, 1, 0), isActive: true),
            for: camera
        )

        _ = makePreviewEntity(
            name: "Key Light",
            kind: "Directional Light",
            matrix: previewTranslationMatrix(SIMD3<Float>(4, 6, 2))
        )

        let gameplay = makePreviewEntity(
            name: "Gameplay",
            kind: "Group",
            matrix: matrix_identity_float4x4
        )

        let hero = makePreviewEntity(
            name: "Hero",
            kind: "Static Mesh",
            matrix: previewTranslationMatrix(SIMD3<Float>(0, 1, 0))
        )
        _ = setComponent(RenderMeshComponent(meshIndex: 1), for: hero)
        _ = setComponent(
            RigidBody(motionType: .dynamic, mass: 80, gravityScale: 1, allowSleep: true),
            for: hero
        )
        _ = setComponent(
            Collider(
                shape: .capsule(radius: 0.35, halfHeight: 0.9, center: SIMD3<Float>(0, 0.9, 0))
            ),
            for: hero
        )

        let socket = makePreviewEntity(
            name: "Sword Socket",
            kind: "Locator",
            matrix: previewTranslationMatrix(SIMD3<Float>(0.55, 1.2, 0.15))
        )

        let ground = makePreviewEntity(
            name: "Ground",
            kind: "Static Mesh",
            matrix: previewTranslationScaleMatrix(
                translation: SIMD3<Float>(0, -1, 0),
                scale: SIMD3<Float>(8, 0.5, 8)
            )
        )
        _ = setComponent(RenderMeshComponent(meshIndex: 0), for: ground)
        _ = setComponent(
            RigidBody(motionType: .static, mass: 0, gravityScale: 0, allowSleep: false),
            for: ground
        )
        _ = setComponent(
            Collider(
                shape: .box(
                    halfExtents: SIMD3<Float>(8, 0.5, 8),
                    center: SIMD3<Float>(0, -0.5, 0)
                )
            ),
            for: ground
        )

        let constraint = makePreviewEntity(
            name: "Hero Follow",
            kind: "Constraint",
            matrix: matrix_identity_float4x4
        )
        _ = setComponent(
            Constraint(
                constraintType: .distance,
                entityA: hero,
                entityB: camera,
                minLimit: 2.5,
                maxLimit: 6.0,
                isEnabled: true
            ),
            for: constraint
        )

        _ = setParent(gameplay, for: hero)
        _ = setParent(hero, for: socket)
        _ = setParent(gameplay, for: ground)
        _ = setParent(gameplay, for: constraint)
        propagateTransforms()
        setResource(
            SceneBootstrapDefaultsResource(
                defaultSelection: hero,
                defaultExpanded: [gameplay, hero]
            )
        )
    }

    private mutating func makePreviewEntity(name: String,
                                            kind: String,
                                            matrix: simd_float4x4) -> EntityID {
        let entity = createEntity()
        _ = setComponent(SceneNameComponent(value: name), for: entity)
        _ = setComponent(SceneKindComponent(value: kind), for: entity)
        _ = setLocalTransform(LocalTransform(matrix: matrix), for: entity)
        return entity
    }
}

private func previewTranslationMatrix(_ translation: SIMD3<Float>) -> simd_float4x4 {
    simd_float4x4(rows: [
        SIMD4<Float>(1, 0, 0, translation.x),
        SIMD4<Float>(0, 1, 0, translation.y),
        SIMD4<Float>(0, 0, 1, translation.z),
        SIMD4<Float>(0, 0, 0, 1),
    ])
}

private func previewScaleMatrix(_ scale: SIMD3<Float>) -> simd_float4x4 {
    simd_float4x4(rows: [
        SIMD4<Float>(scale.x, 0, 0, 0),
        SIMD4<Float>(0, scale.y, 0, 0),
        SIMD4<Float>(0, 0, scale.z, 0),
        SIMD4<Float>(0, 0, 0, 1),
    ])
}

private func previewTranslationScaleMatrix(translation: SIMD3<Float>,
                                           scale: SIMD3<Float>) -> simd_float4x4 {
    previewTranslationMatrix(translation) * previewScaleMatrix(scale)
}